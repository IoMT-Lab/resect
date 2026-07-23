import 'dart:async';
import 'dart:io';

import 'package:resect_signatures/resect_signatures.dart';

import '../database/artifact_database.dart';
import '../models/target_arch.dart';
import 'hook_classifier.dart';
import 'llm_client.dart';
import 'llm_profiles.dart';
import 'rag_index.dart';

export 'hook_classifier.dart' show ClassificationResult, HookInvariant, InvariantResult;

/// Authoritative platform context fed to the LLM ahead of any
/// retrieval / few-shot blocks. The whole point of this struct is to
/// stop the model from hallucinating things we already know:
///
/// - `archString` — from `FirmwareRecord.machine` (the ELF
///   `e_machine` field). Names the CPU family explicitly so the
///   model doesn't have to infer.
/// - `replContent` — the verbatim text of the project's Renode
///   `.repl` file. Tiny (~50 lines for typical STM32 boards) and
///   carries authoritative peripheral name → base address mappings
///   like `rcc: Miscellaneous.STM32F4_RCC @ sysbus 0x40023800`.
///   Eliminates the silent-wrong-base-address failure mode where
///   the model guesses an offset from training data and writes to
///   the wrong register.
/// - `firmwareSymbols` — names from the cached call graph; useful
///   for the model to know what other functions exist in the
///   firmware (so e.g. it can call a real `HAL_GetTick` symbol
///   instead of inventing a helper). No addresses for v1 —
///   callgraph-dart's `Symbol` doesn't preserve them.
///
/// What this doesn't carry: bit-level register layouts ("PLLON is
/// bit 24 of RCC_CR"). The `.repl` doesn't have them; that gap is
/// the LLM's job to fill from RAG-indexed reference manuals.
class PlatformFacts {
  const PlatformFacts({
    required this.archString,
    required this.replContent,
    required this.replPath,
    required this.firmwareSymbols,
  });

  final String archString;
  final String replContent;

  /// Original path on disk — used as the section caption ("from
  /// `<basename>.repl`") and for debugging.
  final String replPath;

  final List<String> firmwareSymbols;

  /// Construct from the project's raw inputs. Returns null when any
  /// required piece is missing (no `.repl` set, no architecture
  /// detected, etc.) — caller should generate without a `## Platform`
  /// block in that case rather than emitting a half-empty one.
  static Future<PlatformFacts?> tryBuild({
    required String? replPath,
    required String? archString,
    required Iterable<String> firmwareSymbols,
  }) async {
    if (replPath == null || replPath.isEmpty) return null;
    if (archString == null || archString.isEmpty) return null;
    final file = File(replPath);
    if (!file.existsSync()) return null;
    final content = await file.readAsString();
    return PlatformFacts(
      archString: archString,
      replContent: content,
      replPath: replPath,
      firmwareSymbols: firmwareSymbols.toList(growable: false),
    );
  }

  /// Short caption for the dialog's "Context: …" status line.
  String summary() {
    final replName = replPath.split('/').last;
    final peripheralCount = '@'.allMatches(replContent).length;
    return '$archString · $replName ($peripheralCount peripherals) · '
        '${firmwareSymbols.length} symbols';
  }
}

/// Orchestrates a single LLM-driven hook generation pass.
///
/// Reads top-K context chunks from the per-project [RagIndex], composes a
/// system + user prompt loaded with the Renode/IronPython gotchas we've
/// learned, and streams tokens from [LlmClient.generate] straight back
/// to the caller (the UI editor).
///
/// One-shot — no chat history, no agentic auto-retry. Regenerate = a
/// fresh call with a (possibly edited) prompt.
class LlmHookGenerator {
  LlmHookGenerator({
    required this.index,
    required this.client,
    this.artifactDb,
    HookClassifier? classifier,
  }) : classifier = classifier ?? const HookClassifier();

  final RagIndex index;
  final LlmClient client;

  /// Optional handle on the artifact DB. When provided AND the
  /// hook is targeting a named symbol, we pin that symbol's
  /// `decompilation` chunk at the top of the `## Project context`
  /// block — the model's single most-useful input is the actual
  /// source of the function it's replacing. Null on Library tabs
  /// that don't pass this through; retrieval still works via the
  /// regular cosine-ranked path.
  ///
  /// Also gates the classifier path: classification requires
  /// pulling the decompilation + data_symbols from this DB; without
  /// it, [generate] skips classification entirely and goes
  /// straight to the LLM.
  final ArtifactDatabase? artifactDb;

  /// Deterministic rule-based classifier that maps a function to a
  /// catalog template + invariant. Tried first in [generate]; when
  /// it matches, the catalog hook is materialised directly and the
  /// LLM is not invoked. When it returns null (no rule fits), the
  /// LLM path runs as before.
  final HookClassifier classifier;

  /// Result of the most recent classification attempt. Non-null
  /// when [generate] last produced a catalog-materialised hook;
  /// null when the LLM path was taken (or no classification was
  /// attempted, e.g. no target symbol). Exposed for the dialog so
  /// it can render the rule + template + invariant in the score
  /// breakdown, and so the scorer can evaluate the invariant
  /// against the harness's captured return values.
  ClassificationResult? get lastClassification => _lastClassification;
  ClassificationResult? _lastClassification;

  /// Whether the authorship watchdog fired on the most recent
  /// [generateEvents]/[generate] LLM-path call — i.e. the first
  /// attempt spiralled past `authorship.watchdogThinkChunks` with no
  /// response and a narrower think-off retry ran. Exposed so the
  /// auto-tune orchestrator can record `watchdog_fired` in the
  /// per-round trace. Reset at the start of each LLM-path call;
  /// false after a classifier short-circuit (no LLM ran).
  bool get lastWatchdogFired => _lastWatchdogFired;
  bool _lastWatchdogFired = false;

  /// How many chunks total to inject into the prompt's `## Project context`
  /// block. 10 × ~500 tokens ≈ 5 KB of text, well under Gemma's window.
  static const _kTotalContext = 10;

  /// How many of those slots are reserved for `source_kind='hook'`
  /// few-shot examples. The remaining slots come from docs / symbols
  /// / Ghidra-extracted decompilation / data types / data symbols /
  /// memory map.
  static const _kHookExamples = 5;

  /// `source_kind`s pulled into the `## Project context` block.
  /// The Ghidra-derived kinds (`decompilation`, `data_type`,
  /// `data_symbol`, `memory_section`) only exist when MODULE_GHIDRA
  /// has been used to extract them; on projects without Ghidra they
  /// just have no rows, so listing them here is safe.
  static const _kContextKinds = <String>{
    'doc',
    'symbol',
    'decompilation',
    'data_type',
    'data_symbol',
    'memory_section',
  };

  /// Literal prefixes that open a comment line of meta-narration
  /// (the failure mode where the model fills its output budget
  /// explaining why it can't produce a hook instead of either
  /// producing one or emitting the three-line stub). Each entry is
  /// a STRING the model would have to emit to start such a
  /// preamble; Ollama halts generation at the first match.
  ///
  /// Real hook comments don't open with any of these — they either
  /// cite a source (`# from: ...`) or label a section (`# entry`,
  /// `# write rcc enable bit`). Safe to halt aggressively.
  ///
  /// If a future generation slips through with a new preamble
  /// opener (`# Note that`, `# Generally`, etc.), add the literal
  /// prefix here. The list is supposed to grow as we learn.
  static const _kStopSequences = <String>[
    '\n# Since',
    '\n# Based on',
    '\n# Typically',
    '\n# Standard',
    '\n# In STM',
    '\n# In ST',
    '\n# In the STM',
    '\n# The function',
    '\n# This function',
    '\n# Note that',
  ];

  /// Cache of the most recently composed prompt. Populated each
  /// time [generate] runs (before any token streams from Ollama).
  /// Exists so callers — tests, the dialog's "Show prompt" toggle —
  /// can inspect exactly what the model saw. Not stable across
  /// concurrent calls; [generate] is one-shot per dialog so this
  /// is fine.
  String? get lastComposedPrompt => _lastComposedPrompt;
  String? _lastComposedPrompt;

  /// System prompt. The biggest lever for output quality: the LLM gets
  /// this verbatim ahead of every prompt. Two non-obvious constraints
  /// drive its shape:
  ///
  /// 1. Hooks don't write `cpu.SetRegister(0, v); cpu.PC = cpu.LR`
  ///    directly. The hooks-dart catalog ships helper Python modules
  ///    (`set_return_value`, `pointer`, `variables`, …) that handle
  ///    the low-level Renode API, `RegisterValue.Create`, and the PC
  ///    twiddling. Catalog hooks are 2-line affairs — `import
  ///    set_return_value; setReturnValue(cpu, 42)`. Without telling
  ///    the LLM these modules exist, it hallucinates the wrong
  ///    abstraction layer (`machine.SystemBus.read_word`, etc.).
  /// 2. The LLM kept wrapping output in
  ///    `def <function_name>(): ...` — defining but never calling — so
  ///    the hook ran and did nothing. The rule against `def` was
  ///    buried and got ignored. Now it's the first thing in the
  ///    output rules and has an explicit "the body executes top-down"
  ///    framing.
  static const systemPrompt = '''
You are writing IronPython 2.7 code for a Renode hook. Renode installs
the code at the function's entry address; the hook runs INSTEAD OF
the function body when the firmware calls it.

# Your job: SUBSTITUTE for the function, do not REPLICATE it

Most embedded HAL functions you'll see in the prompt do one of these:
- Touch peripheral registers (clock enables, GPIO config, NVIC setup).
- Wait on hardware state (poll a ready flag).
- Set up interrupts.

Replicating those is the failure mode, not the goal. Renode either
doesn't model the peripheral (so the access is unhandled and the
firmware crashes) or does model it but doesn't care about the bits
(so the write is wasted I/O). Either way, the hook should NOT do
the write.

Use the decompilation (in `## Project context`) for THREE things ONLY:

1. **Return type.** Functions returning `void` get `setReturnValue(cpu, 0)`
   (the helper still has to advance PC). Functions returning a status
   code get `setReturnValue(cpu, 0)` (HAL_OK / SUCCESS / READY).
2. **Out-pointer arguments.** If a parameter is a `T*` the function
   writes to, fill the buffer with safe defaults via
   `pointer.writeData(cpu, ptr, [0] * N)` where N is the struct size
   from the `data_type` chunk. The caller will read those bytes;
   zeros usually parse as "default config".
3. **Classification.** Read the decompilation to decide: is this
   function purely peripheral-touching with no outputs? Then the hook
   is the canonical no-op return. Are there genuine outputs? Fill
   them, then return.

DO NOT replicate:
- Peripheral register writes (`*(uint32_t*)0x4800XXXX = ...` in the
  decompilation).
- Peripheral register reads (same form).
- Bus-synchronization dummy reads (the read-after-write the real HAL
  does as a memory barrier — emulation doesn't need it).
- "Wait for ready" polling loops.
- Interrupt enable/disable sequences.

If the decompilation shows ONLY hardware-touching operations and no
out-pointer writes, the hook is exactly:

    import set_return_value
    setReturnValue(cpu, 0)

That's the right answer for clock-enable, GPIO-config, NVIC-setup,
peripheral-reset, and most LL_* / __HAL_* / `*_Init` functions.

# Canonical substitute shapes (match one of these)

Peripheral side-effect, void return (the most common case):
    import set_return_value
    setReturnValue(cpu, 0)

Status / state query returning a "ready" / "ok" code:
    import set_return_value
    setReturnValue(cpu, 0)        # HAL_OK / READY / SUCCESS

Out-pointer filler — caller passes a struct pointer the function
writes a result into. Get the struct's size from the `data_type`
chunk in `## Project context`; do not invent the layout. **BOTH
imports below are required — `pointer.writeData` without
`import pointer` raises NameError at runtime.**
    import set_return_value
    import pointer                                 # REQUIRED — pointer.writeData below
    # from: data_type RCC_OscInitTypeDef
    out_ptr = int(cpu.GetRegister(0).RawValue)
    pointer.writeData(cpu, out_ptr, [0] * 36)   # struct size in bytes
    setReturnValue(cpu, 0)

Wait-for-flag — caller is polling for "ready"; hook reports ready
immediately:
    import set_return_value
    setReturnValue(cpu, 0)

Pure computation (rare for HAL code) — use cpu.GetRegister to read
args, return the result. No bus traffic.
    import set_return_value
    a = int(cpu.GetRegister(0).RawValue)
    b = int(cpu.GetRegister(1).RawValue)
    setReturnValue(cpu, a + b)

None of these examples reads or writes a peripheral register. That
is intentional. Substitute hooks don't touch hardware.

# When you don't have any decompilation data, stub — exactly 3 lines:

import set_return_value
# TODO: <name the one specific missing fact in <= 80 chars>
setReturnValue(cpu, 0)

No preamble. No explanation. No commentary about what the function
"typically" does. The TODO line names the missing fact — that's the
entire output. Do not narrate why you chose to stub. Do not list
possibilities. Do not enumerate registers you're guessing at.

# Output mechanics

Return ONLY the Python source. No markdown fences. No C syntax (no
`#include`, no `/* */`, no semicolons).

The hook body executes top-down when the function is called. Top-level
statements run immediately. Do NOT wrap your output in
`def <name>(): ...` — defining a function won't call it, and the hook
will do nothing.

**Imports are mandatory and one-to-one with module references.** If
your body uses `pointer.writeData(...)`, you MUST `import pointer`.
If you use `variables.setVariable(...)`, you MUST `import variables`.
If you use `setReturnValue(cpu, ...)`, you MUST `import
set_return_value` (note: the module is snake_case, the function is
camelCase). A reference without its matching `import` is a NameError
at runtime — the hook silently does nothing. The canonical shapes
below already include every import they need; never drop one when
mirroring the shape.

# Available imports (snake_case modules, camelCase functions)

The helpers below are auto-loaded into the hook scope. **Module
names are snake_case; function names are camelCase. They are NOT
the same string.** `import set_return_value` gives you a function
called `setReturnValue`. Calling `set_return_value(cpu, 0)` raises
NameError at runtime. Always:

    import set_return_value
    setReturnValue(cpu, 0)        # camelCase function — correct
    # set_return_value(cpu, 0)    # snake_case — NameError

- `import set_return_value` — `setReturnValue(cpu, value)` sets the
  return register and advances PC to the caller using the right
  convention for the loaded ELF's architecture. Every hook ends
  with this.
- `import pointer` — `writeData(cpu, ptr, data)` writes a byte
  sequence into emulated memory (used to fill out-pointer args).
  `readData(cpu, ptr, size)` reads bytes back.
- `import variables` — `setVariable(name, value)` / `getVariable(name,
  default=None)` / `incrementVariable(name, default=0, increment=1)`
  persist state across firings of the same hook.
- `import comms` — only relevant for off-device I/O hooks; ignore
  for substitute-style functions.

# IronPython 2.7 quirks (relevant when you fill out-pointer buffers)

This is Python **2.7** under .NET — not 3.x. Several Python-3-isms
don't exist:

- No `int.from_bytes(...)` / `int.to_bytes(...)`. Use `struct`:
  `struct.unpack('<I', bytes(raw[0:4]))[0]` for little-endian uint32.
- No f-strings. Use `'%d' % x` or `.format()`.
- `print` is a statement, not a function (or add
  `from __future__ import print_function`).
- No `bytes(int)` constructor. `bytes(5)` returns the string `'5'`,
  not 5 NUL bytes.
''';

  /// Generate a hook body for [userPrompt], optionally targeting the
  /// named symbol [targetSymbol] (when the user is doing a Replacement
  /// hook). Streams tokens as they arrive from Ollama.
  ///
  /// The retrieved-context section is built by:
  ///   1. Embedding `userPrompt + targetSymbol` once.
  ///   2. Pulling top-[_kHookExamples] chunks of `source_kind='hook'`
  ///      for the few-shot block.
  ///   3. Pulling top-(K - kHookExamples) from `{doc, symbol}` for the
  ///      project-context block.
  /// Response-only convenience wrapper — delegates to
  /// [generateEvents] and yields just the hook-body text. The
  /// synthesizer's mid-run fallback buffers this, so it must see
  /// ONLY body chunks (no thinking); filtering to [LlmResponseChunk]
  /// guarantees that and inherits the watchdog protection below.
  Stream<String> generate({
    required String userPrompt,
    String? targetSymbol,
    String? elfHash,
    List<String> targetCallers = const [],
    List<String> targetCallees = const [],
    PlatformFacts? platform,
    FunctionSignature? signature,
    TargetArch? targetArch,
  }) async* {
    await for (final ev in generateEvents(
      userPrompt: userPrompt,
      targetSymbol: targetSymbol,
      elfHash: elfHash,
      targetCallers: targetCallers,
      targetCallees: targetCallees,
      platform: platform,
      signature: signature,
      targetArch: targetArch,
    )) {
      if (ev is LlmResponseChunk) yield ev.text;
    }
  }

  /// Discriminated-event hook authorship.
  ///
  /// Yields thinking + response chunks via [LlmStreamEvent] so the
  /// Hook Database dialog and the auto-tune modal can surface the
  /// model's reasoning trace alongside the streaming hook body.
  /// Classifier hits short-circuit by emitting a single
  /// [LlmResponseChunk] with the catalog hook code — no LLM
  /// round-trip. The LLM path runs the think-on `authorship` profile
  /// wrapped by a watchdog (Gemma thinking is uncappable, so an
  /// unproductive spiral is bounded and retried once, narrower).
  Stream<LlmStreamEvent> generateEvents({
    required String userPrompt,
    String? targetSymbol,
    String? elfHash,
    List<String> targetCallers = const [],
    List<String> targetCallees = const [],
    PlatformFacts? platform,
    FunctionSignature? signature,
    TargetArch? targetArch,
  }) async* {
    _lastClassification = null;
    final cls = await _tryClassify(
      targetSymbol: targetSymbol,
      elfHash: elfHash,
      signature: signature,
    );
    if (cls != null) {
      _lastClassification = cls;
      yield LlmResponseChunk(cls.hook.code);
      return;
    }

    final prompt = await composePrompt(
      userPrompt: userPrompt,
      targetSymbol: targetSymbol,
      elfHash: elfHash,
      targetCallers: targetCallers,
      targetCallees: targetCallees,
      platform: platform,
      signature: signature,
      targetArch: targetArch,
    );

    yield* _authorWithWatchdog(prompt);
  }

  /// Stream the hook body under the `authorship` profile, watching
  /// for an unproductive thinking spiral. If the model emits more
  /// than `watchdogThinkChunks` thinking chunks without a single
  /// response byte, the first attempt is abandoned (breaking the
  /// `await for` cancels the subscription; the closed connection
  /// aborts Ollama's generation) and ONE narrower retry runs with
  /// thinking disabled and an explicit "emit the body now"
  /// directive. Applies to every consumer (dialog, auto-tune,
  /// synthesizer) since they all route through here.
  Stream<LlmStreamEvent> _authorWithWatchdog(String prompt) async* {
    const p = LlmProfiles.authorship;
    _lastWatchdogFired = false;

    var thinkingChunks = 0;
    var sawResponse = false;
    var tripped = false;

    await for (final ev in client.generateEvents(
      prompt,
      system: systemPrompt,
      stop: _kStopSequences,
      think: p.think,
      temperature: p.temperature,
      topP: p.topP,
      topK: p.topK,
      numCtx: p.numCtx,
      numPredict: p.numPredict,
    )) {
      if (ev is LlmThinkingChunk) {
        thinkingChunks++;
        final limit = p.watchdogThinkChunks;
        if (!sawResponse && limit != null && thinkingChunks > limit) {
          tripped = true;
          break; // abandon attempt 1; connection close aborts Ollama.
        }
      } else if (ev is LlmResponseChunk) {
        sawResponse = true;
      }
      yield ev;
    }

    if (!tripped) return;

    // Watchdog fired — one narrower retry: thinking off, an explicit
    // directive to stop reasoning and emit the body. Stage-1 shape
    // selection (see TODO) would give a tighter scaffold here; until
    // then, disabling thinking is the decisive lever.
    _lastWatchdogFired = true;
    final narrowed = '$prompt\n\n'
        '## Constraint\n'
        'Do NOT reason further. Emit ONLY the Python hook body now, '
        'nothing else.';
    yield* client.generateEvents(
      narrowed,
      system: systemPrompt,
      stop: _kStopSequences,
      think: false,
      temperature: 0.0,
      topP: p.topP,
      topK: p.topK,
      numCtx: p.numCtx,
      numPredict: p.numPredict,
    );
  }

  /// Pull the target's decompilation + the project's data_symbols
  /// from the artifact DB and hand them to [classifier]. Returns
  /// null when any required input is missing (the LLM path takes
  /// over from there).
  Future<ClassificationResult?> _tryClassify({
    required String? targetSymbol,
    required String? elfHash,
    required FunctionSignature? signature,
  }) async {
    final db = artifactDb;
    if (db == null ||
        targetSymbol == null ||
        elfHash == null ||
        signature == null) {
      return null;
    }
    final decompilation = await db.decompilationFor(
      elfHash: elfHash,
      functionName: targetSymbol,
    );
    if (decompilation == null || decompilation.isEmpty) return null;
    final rows = await db.dataSymbolsFor(elfHash);
    final dataSymbols = <String, DataSymbol>{
      for (final r in rows)
        r.symbolName: DataSymbol(
          name: r.symbolName,
          address: r.address,
          type: r.typeName,
          size: r.size,
        ),
    };
    return classifier.classify(
      functionName: targetSymbol,
      signature: signature,
      decompilation: decompilation,
      dataSymbols: dataSymbols,
    );
  }

  /// Compose the user prompt exactly as [generate] would — same
  /// retrieval, same pin, same `## Project context` ordering — but
  /// WITHOUT invoking Ollama. Used by the integration test in
  /// `tool/test_rag_end_to_end.dart` to assert prompt content
  /// (pinned decompilation header, chunk ordering) deterministically
  /// without spending wall-clock on a real generation.
  ///
  /// Side effect: writes [lastComposedPrompt] just like the streaming
  /// path does, so callers that want both ("compose, inspect, then
  /// generate") can do so back-to-back.
  Future<String> composePrompt({
    required String userPrompt,
    String? targetSymbol,
    String? elfHash,
    List<String> targetCallers = const [],
    List<String> targetCallees = const [],
    PlatformFacts? platform,
    FunctionSignature? signature,
    TargetArch? targetArch,
  }) async {
    final query = [userPrompt, ?targetSymbol].join('\n');

    final hookHits = await index.retrieve(
      query,
      topK: _kHookExamples,
      kinds: {'hook'},
    );
    final hookIds = hookHits.map((h) => h.id).toSet();

    // Pin the target function's decompilation chunk first (when
    // available). The model's single most-useful input is the
    // actual source of the function it's replacing — cosine ranking
    // is a poor substitute for an exact lookup when we know the
    // symbol name.
    final pinnedHits = <RagHit>[];
    final pinnedDecomp = await _pinnedDecompilationHit(
      elfHash: elfHash,
      targetSymbol: targetSymbol,
    );
    if (pinnedDecomp != null) pinnedHits.add(pinnedDecomp);

    // Also pin `data_type` chunks for each named (non-primitive)
    // pointer parameter in the signature. Without these, the model
    // cannot satisfy the `pointer.writeData(cpu, ptr, [0] * N)`
    // canonical shape (it has no struct size) and falls back to
    // `setReturnValue(cpu, 0)` even when out-pointer writes are
    // exactly what the function does. Cosine ranking against the
    // user prompt loses these chunks because the prompt names the
    // function, not its parameter types.
    pinnedHits.addAll(await pinnedDataTypeHits(
      elfHash: elfHash,
      signature: signature,
    ));

    final pinnedIds = pinnedHits.map((h) => h.id).toSet();
    // The pinned hits use synthetic negative IDs that don't exist in
    // the RAG, so the `exclude: pinnedIds` set won't stop cosine from
    // pulling the SAME (sourceKind, sourceId) again as a real chunk
    // — leaving the function's own decomp glued into the prompt
    // twice. Post-filter cosine hits by (kind, id) to drop dupes.
    final pinnedKeys = {
      for (final h in pinnedHits) (h.sourceKind, h.sourceId),
    };

    final remainingCtxK =
        _kTotalContext - _kHookExamples - pinnedHits.length;
    final rawCtxHits = remainingCtxK <= 0
        ? const <RagHit>[]
        : await index.retrieve(
            query,
            // Over-fetch so the dedup post-filter doesn't shrink us
            // below the target slot count when one or more cosine
            // hits collide with a pinned (kind, id).
            topK: remainingCtxK + pinnedHits.length,
            kinds: _kContextKinds,
            exclude: hookIds.union(pinnedIds),
          );
    final ctxHits = rawCtxHits
        .where((h) => !pinnedKeys.contains((h.sourceKind, h.sourceId)))
        .take(remainingCtxK)
        .toList();

    final orderedCtxHits = <RagHit>[
      ...pinnedHits,
      ...ctxHits,
    ];

    final prompt = _composePrompt(
      userPrompt: userPrompt,
      targetSymbol: targetSymbol,
      targetCallers: targetCallers,
      targetCallees: targetCallees,
      hookExamples: hookHits,
      contextHits: orderedCtxHits,
      platform: platform,
      signature: signature,
      targetArch: targetArch,
    );
    _lastComposedPrompt = prompt;
    return prompt;
  }

  /// Look up the `decompilation` chunk for [targetSymbol] under
  /// [elfHash] and return it as a synthetic [RagHit] suitable for
  /// pinning at the top of the project-context block. Returns null
  /// when:
  /// - No artifact DB was wired in,
  /// - No elfHash or targetSymbol was passed,
  /// - The Ghidra module hasn't extracted decompilation for this
  ///   ELF yet, or
  /// - The specific symbol isn't in the decompilation cache.
  Future<RagHit?> _pinnedDecompilationHit({
    required String? elfHash,
    required String? targetSymbol,
  }) async {
    final db = artifactDb;
    if (db == null || elfHash == null || targetSymbol == null) return null;
    final src = await db.decompilationFor(
      elfHash: elfHash,
      functionName: targetSymbol,
    );
    if (src == null || src.isEmpty) return null;
    // Score is informational only — this hit gets pinned, not
    // ranked. Use a synthetic id (negative so it can't collide with
    // a real chunks-table id) and a score of 1.0 to make its
    // pinned-at-top status obvious if anything ever sorts on it.
    return RagHit(
      id: -1,
      sourceKind: 'decompilation',
      sourceId: targetSymbol,
      text: src,
      score: 1.0,
    );
  }

  /// Look up `data_type` rows for each named, non-primitive pointer
  /// parameter in [signature] and return them as synthetic [RagHit]s
  /// for pinning. The model needs the struct's byte size + field
  /// layout to write `pointer.writeData(cpu, ptr, [0] * N)`; without
  /// it, the only allowed exit per the system prompt is the no-op.
  ///
  /// Ghidra stores types under qualified paths like
  /// `/DWARF/nvm_db.c/NVMDB_info`; we match by suffix `/NVMDB_info`
  /// (or exact equality, in case a type lives at the root).
  /// Synthetic ids start at -2 (−1 is taken by the pinned decomp).
  /// Public (no leading underscore) so the integration test in
  /// `test/pinned_data_type_hits_test.dart` can seed an in-memory
  /// `ArtifactDatabase` and observe the lookup directly.
  Future<List<RagHit>> pinnedDataTypeHits({
    required String? elfHash,
    required FunctionSignature? signature,
  }) async {
    final db = artifactDb;
    if (db == null || elfHash == null || signature == null) {
      return const [];
    }
    final wantedBases = <String>{};
    for (final p in signature.parameters) {
      final base = basePointerTypeName(p.type);
      if (base != null) wantedBases.add(base);
    }
    if (wantedBases.isEmpty) return const [];

    final allTypes = await db.dataTypesFor(elfHash);
    final hits = <RagHit>[];
    var nextId = -2;
    for (final base in wantedBases) {
      GhidraDataType? match;
      for (final t in allTypes) {
        if (t.typeName == base || t.typeName.endsWith('/$base')) {
          match = t;
          break;
        }
      }
      if (match == null) continue;
      hits.add(RagHit(
        id: nextId,
        sourceKind: 'data_type',
        sourceId: match.typeName,
        text: match.definitionText,
        score: 1.0,
      ));
      nextId--;
    }
    return hits;
  }

  /// Pull the named pointee type out of [paramType] when it's a
  /// pointer to a user-defined type the model could look up. Returns
  /// null for non-pointers, void pointers, function pointers, and
  /// primitives we know have no useful struct layout.
  ///
  /// Public (no leading underscore) so the unit tests in
  /// `test/hook_pointer_type_test.dart` can call it directly; the
  /// behavior on edge cases (`const`, function pointers, `void *`,
  /// double pointers) is what those tests pin down.
  static String? basePointerTypeName(String paramType) {
    var t = paramType.trim();
    if (!t.contains('*')) return null;
    // Drop the pointer stars first; this leaves multi-space runs
    // where stars used to live (e.g. `NVMDB_info * const` →
    // `NVMDB_info  const`). Collapse so trailing-cvr strip below
    // matches the literal ' const' suffix and doesn't strand a
    // dangling space on the type name.
    t = t.replaceAll('*', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final q in const ['const ', 'volatile ', 'restrict ']) {
      while (t.startsWith(q)) {
        t = t.substring(q.length).trim();
      }
    }
    for (final q in const [' const', ' volatile', ' restrict']) {
      while (t.endsWith(q)) {
        t = t.substring(0, t.length - q.length).trim();
      }
    }
    if (t.isEmpty || t == 'void') return null;
    if (t.contains('(') || t.contains(')')) return null;
    const primitives = <String>{
      'char', 'short', 'int', 'long', 'float', 'double',
      'unsigned', 'signed',
      'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t',
      'int8_t', 'int16_t', 'int32_t', 'int64_t',
      'size_t', 'ssize_t', 'ptrdiff_t',
      'intptr_t', 'uintptr_t',
      'bool', '_Bool', 'byte', 'word',
    };
    if (primitives.contains(t)) return null;
    return t;
  }

  String _composePrompt({
    required String userPrompt,
    required String? targetSymbol,
    required List<String> targetCallers,
    required List<String> targetCallees,
    required List<RagHit> hookExamples,
    required List<RagHit> contextHits,
    required PlatformFacts? platform,
    required FunctionSignature? signature,
    required TargetArch? targetArch,
  }) {
    final b = StringBuffer();

    if (targetArch != null) {
      // Per-arch fallback context. The system prompt sends the
      // model here when no per-function Ghidra signature is
      // available. Goes ahead of `## Platform` so it's the first
      // thing the model anchors on.
      b
        ..writeln('## Architecture')
        ..writeln('CPU: ${targetArch.displayName}')
        ..writeln('Calling convention: ${targetArch.callingConventionName}')
        ..writeln('Return register: ${targetArch.returnRegister}  '
            '(emitted by `setReturnValue` for you)')
        ..writeln('Return mechanism: ${targetArch.returnSnippet}')
        ..writeln('Argument registers (in order): '
            '${targetArch.argRegisters.join(', ')}');
      if (targetArch.glueModuleName.isNotEmpty) {
        b.writeln(
            'Platform glue helper: `import ${targetArch.glueModuleName}` '
            '(for HAL-specific arg extraction patterns)');
      }
      b.writeln();
    }

    if (platform != null) {
      // Authoritative project data — `.repl` peripheral map, ELF
      // architecture, firmware symbol list. Goes first so the model
      // anchors to known facts before consuming retrieved chunks.
      final replBasename = platform.replPath.split('/').last;
      b
        ..writeln('## Platform')
        ..writeln('Architecture: ${platform.archString}')
        ..writeln()
        ..writeln('CPU + peripherals + memory map (from $replBasename):')
        ..writeln('```')
        ..writeln(platform.replContent.trim())
        ..writeln('```')
        ..writeln();
      if (platform.firmwareSymbols.isNotEmpty) {
        // Relevance-rank by name similarity to the target so the
        // model sees `HAL_RCC_*` neighbors first when generating for
        // `HAL_RCC_OscConfig`. Cap to keep context-window pressure
        // down — the whole symbol table can be thousands of entries.
        final ranked =
            _rankSymbols(platform.firmwareSymbols, targetSymbol);
        b
          ..writeln('Firmware symbols (top ${ranked.length} by name '
              'similarity to target):')
          ..writeln(ranked.join(', '))
          ..writeln();
      }
    }

    if (hookExamples.isNotEmpty) {
      b.writeln('## Examples from the catalog');
      for (final h in hookExamples) {
        b
          ..writeln('### ${h.sourceId}')
          ..writeln(h.text.trim())
          ..writeln();
      }
    }

    if (contextHits.isNotEmpty) {
      b.writeln('## Project context');
      for (final h in contextHits) {
        // Decompilation chunks get a clearer header so the model
        // sees "this is the actual function body Ghidra recovered,
        // mimic this" instead of treating it like just another doc.
        // Same for data_type / data_symbol / memory_section — each
        // header names what the chunk is so the `# from:` citations
        // (per Grounding rule #3) have a clean label to reference.
        final header = switch (h.sourceKind) {
          'decompilation' =>
            '### Decompiled source (Ghidra) — ${h.sourceId}',
          'data_type' => '### Data type (Ghidra) — ${h.sourceId}',
          'data_symbol' => '### Data symbols (Ghidra) — ${h.sourceId}',
          'memory_section' => '### Memory map (Ghidra)',
          'doc' => '### Doc: ${h.sourceId}',
          'symbol' => '### Symbol: ${h.sourceId}',
          _ => '### ${h.sourceKind}: ${h.sourceId}',
        };
        b
          ..writeln(header)
          ..writeln(h.text.trim())
          ..writeln();
      }
    }

    if (targetSymbol != null) {
      b
        ..writeln('## Target')
        ..writeln('Function: $targetSymbol');
      if (signature != null) {
        // Authoritative — from Ghidra. Tells the model exactly which
        // register each parameter lives in for THIS function, so it
        // doesn't have to fall back to the generic AAPCS guide.
        b.writeln('Signature: ${signature.summary()}');
        if (signature.parameters.isNotEmpty) {
          b.writeln('Arguments (ABI: ${signature.callingConvention}):');
          for (final p in signature.parameters) {
            final name = p.name.isEmpty ? '<unnamed>' : p.name;
            final storage = p.storage.isEmpty ? '<unknown>' : p.storage;
            b.writeln('  $name  (${p.type})  → $storage');
          }
        }
        b.writeln('Returns: ${signature.returnType}  ← r0');
      }
      if (targetCallers.isNotEmpty) {
        b.writeln('Called by: ${targetCallers.join(', ')}');
      }
      if (targetCallees.isNotEmpty) {
        b.writeln('Calls: ${targetCallees.join(', ')}');
      }
      b.writeln();
    }

    b
      ..writeln('## Request')
      ..writeln(userPrompt.trim());

    return b.toString();
  }

  /// Rank firmware symbols by name-similarity to [target] and return
  /// the top [limit]. The score is the length of the longest shared
  /// prefix — crude but effective for HAL-style codebases where
  /// peers share a `HAL_RCC_*` or `MX_*` prefix. When [target] is
  /// null, returns the first [limit] symbols verbatim (preserves the
  /// call graph's enumeration order, which roughly tracks the ELF
  /// symbol table).
  static List<String> _rankSymbols(
    List<String> symbols,
    String? target, {
    int limit = 200,
  }) {
    if (target == null || target.isEmpty) {
      return symbols.take(limit).toList(growable: false);
    }
    final ranked = symbols.toList()
      ..sort((a, b) {
        final scoreA = _commonPrefixLength(a, target);
        final scoreB = _commonPrefixLength(b, target);
        return scoreB.compareTo(scoreA);
      });
    return ranked.take(limit).toList(growable: false);
  }

  static int _commonPrefixLength(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }
}
