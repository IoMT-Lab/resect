import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/external/ghidra_installer.dart';
import '../services/external/ollama_installer.dart';
import 'config_schema.dart' show which;
import 'env_config.dart';

enum ComponentKind { required, optional }

/// Live detection result for a component (computed, never persisted).
class ComponentStatus {
  const ComponentStatus(this.available, this.detail);

  /// True when the component's prerequisites are present on this machine.
  final bool available;

  /// Short human-readable status, shown next to the toggle.
  final String detail;
}

class ComponentInstallException implements Exception {
  ComponentInstallException(this.message);
  final String message;
  @override
  String toString() => 'ComponentInstallException: $message';
}

/// One frame of a [Component.install] stream. Carries either a log
/// line (appended to the install dialog's scrolling area) OR a
/// progress update (drives the bottom progress bar), or both.
///
/// Routing rule in the dialog: events where [progressFraction] is set
/// update the progress bar in place and DO NOT append to the log —
/// this keeps the 1.4 GB download from producing a 1400-line scroll.
/// Events with only [message] always append to the log.
class InstallEvent {
  const InstallEvent({this.message, this.progressFraction, this.progressLabel});

  /// Log line to append. Null when this event is progress-only.
  final String? message;

  /// 0.0–1.0 fraction for the progress bar. Null means "no progress
  /// update right now"; the bar holds its previous value.
  final double? progressFraction;

  /// Short label rendered beside the progress bar (e.g. "32 MB / 1.3 GB").
  final String? progressLabel;

  /// Convenience constructor for a plain log line.
  const InstallEvent.log(String message) : this(message: message);

  /// Convenience constructor for a progress tick.
  const InstallEvent.progress(double fraction, [String? label])
      : this(progressFraction: fraction, progressLabel: label);
}

/// An optional add-on module surfaced in the System Configuration UI. Enable
/// flags live in `resect.config` under [configKey]; detection is live.
abstract class Component {
  String get id;
  String get title;
  String get description;
  ComponentKind get kind;
  String get configKey;

  /// Whether [install] performs real (user-level) provisioning work.
  bool get installable;

  /// Probe the machine for this component's prerequisites.
  Future<ComponentStatus> detect();

  /// Run user-level installation, emitting [InstallEvent]s for the
  /// install dialog (log lines + progress bar updates). Throws (or
  /// adds an error to the stream) on failure. No-op components
  /// complete immediately. Cancellation: the dialog cancels the
  /// subscription on Cancel-button press, which propagates as a
  /// stream cancel — implementations should clean up via standard
  /// `try`/`finally`.
  Stream<InstallEvent> install();
}

/// One curated entry in the Gemma 4 model picker shown by the
/// System Configuration → Modules → LLM Hook Generation installer.
///
/// Sourced from [ollama.com/library/gemma4](https://ollama.com/library/gemma4)
/// at planning time. When Google ships a new Gemma family or Ollama
/// renames a tag, edit [gemmaCatalog] below — there's no schema, just
/// the list. Users can always opt out via the Advanced custom-tag
/// field in the picker.
class GemmaCatalogEntry {
  const GemmaCatalogEntry({
    required this.tag,
    required this.downloadSize,
    required this.summary,
    this.recommended = false,
  });

  /// Exact Ollama tag (e.g. `gemma4:12b`). Passed verbatim to
  /// `ollama pull`.
  final String tag;

  /// Human-readable download size (e.g. `7.6 GB`). Cosmetic.
  final String downloadSize;

  /// One-line "good for" description shown under the tag.
  final String summary;

  /// Pre-selected in the picker when there's no current `LLM_MODEL`
  /// in resect.config. Exactly one entry should set this to true.
  final bool recommended;
}

/// Curated Gemma 4 tags exposed in the model picker. Edit when
/// Ollama publishes new variants — there's no schema, just this list.
const gemmaCatalog = <GemmaCatalogEntry>[
  GemmaCatalogEntry(
    tag: 'gemma4:e2b',
    downloadSize: '7.2 GB',
    summary: 'Smallest edge variant — phones / Pi / Jetson. Fastest, '
        'lowest quality.',
  ),
  GemmaCatalogEntry(
    tag: 'gemma4:e4b',
    downloadSize: '9.6 GB',
    summary: 'Recommended. Produces the same hook quality as gemma4:12b '
        'at roughly an order of magnitude less compute (verified on '
        'the random-10 hook-gen sweep, 2026-06-11).',
    recommended: true,
  ),
  GemmaCatalogEntry(
    tag: 'gemma4:12b',
    downloadSize: '7.6 GB',
    summary: 'Heavier. Same hook-gen quality as gemma4:e4b in our '
        'measurements — useful if you have spare VRAM and want it '
        'for general-purpose use beyond hook gen.',
  ),
  GemmaCatalogEntry(
    tag: 'gemma4:26b',
    downloadSize: '18 GB',
    summary: 'Better instruction-following. Wants a discrete GPU.',
  ),
  GemmaCatalogEntry(
    tag: 'gemma4:31b',
    downloadSize: '20 GB',
    summary: 'Best quality. Workstation-class GPU territory.',
  ),
];

/// LLM-assisted hook generation via local Ollama + Gemma + RAG.
///
/// Detect probes three things — an Ollama binary (system PATH OR our
/// user-local managed install), the user-chosen inference model tag,
/// and the `nomic-embed-text` embedding model (for RAG). `pdftotext`
/// is *checked* but not required: if missing, RAG indexing falls back
/// to text-only docs and the user gets a one-time warning.
///
/// Install walks the same phases. The Ollama install runs entirely
/// inside Resect's UI via [OllamaInstaller] — no terminal pop-up, no
/// PolicyKit dialog. See that class for the rationale.
class LlmHookGenComponent extends Component {
  LlmHookGenComponent({OllamaInstaller? installer})
      : installer = installer ?? OllamaInstaller();

  static const _embedModel = 'nomic-embed-text';
  static const _defaultModel = 'gemma4:e4b';

  /// Owned by [Component] lifetime, *not* shared across components.
  /// The Riverpod wrapper in the UI holds a singleton with a
  /// lifecycle-tied `onDispose` so the daemon dies when Resect closes.
  final OllamaInstaller installer;

  @override
  String get id => 'llm_hookgen';
  @override
  String get title => 'LLM Hook Generation';
  @override
  String get description =>
      'Generate hook code with a local Ollama + Gemma model.';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_LLM_HOOKGEN';
  @override
  bool get installable => true;

  /// Read the user's configured inference-model tag, falling back to a
  /// sensible default when the install flow hasn't run yet.
  String _inferenceModel() {
    final tag = EnvConfig.load().get('LLM_MODEL') ?? '';
    return tag.isEmpty ? _defaultModel : tag;
  }

  /// Host:port to point the Ollama CLI at. Prefers the value written
  /// by `install()` after `ensureDaemonRunning`; falls back to the
  /// installer's local-daemon host when the config key is empty
  /// (e.g. before the first install).
  String _ollamaHost() {
    final cfg = EnvConfig.load().get('LLM_OLLAMA_HOST') ?? '';
    return cfg.isEmpty ? OllamaInstaller.localHost : cfg;
  }

  @override
  Future<ComponentStatus> detect() async {
    final ollama = installer.resolveBinary();
    if (ollama == null) {
      return const ComponentStatus(false, 'Ollama not installed');
    }
    // Route the CLI through whichever daemon `install()` ended up
    // spawning. The user-local daemon lives on 11435 (so it doesn't
    // conflict with any system Ollama on 11434), and the models are
    // registered there — without OLLAMA_HOST the CLI hits the
    // default and reports an empty list, which previously made the
    // Modules tab show "missing" right after a successful install.
    final host = _ollamaHost();
    // If we're managing the daemon and it isn't responsive, bring
    // it up. ensureDaemonRunning pings first and is idempotent —
    // costs ~one HTTP request when the daemon is already alive.
    if (!installer.isSystemInstall) {
      try {
        await installer.ensureDaemonRunning();
      } catch (_) {
        // Fall through to the list call so the user sees the actual
        // CLI error message instead of a synthesized one.
      }
    }
    final inferenceTag = _inferenceModel();
    List<String> installedTags;
    try {
      final r = await Process.run(
        ollama,
        ['list'],
        environment: {
          ...Platform.environment,
          'OLLAMA_HOST': host,
        },
      );
      installedTags = (r.stdout as String)
          .split('\n')
          .skip(1) // header row
          .map((l) => l.trim().split(RegExp(r'\s+')).firstOrNull ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const ComponentStatus(false, 'Ollama present but not responding');
    }
    final hasInference =
        installedTags.any((t) => _tagMatches(t, inferenceTag));
    final hasEmbed = installedTags.any((t) => _tagMatches(t, _embedModel));
    if (hasInference && hasEmbed) {
      return ComponentStatus(true, 'Ready — $inferenceTag + $_embedModel');
    }
    final missing = <String>[
      if (!hasInference) inferenceTag,
      if (!hasEmbed) _embedModel,
    ].join(', ');
    return ComponentStatus(false, 'Missing: $missing');
  }

  /// Install drives the in-app installer + model pulls.
  ///
  /// `await for` instead of `yield*` is intentional — `yield*` in
  /// `async*` forwards inner-stream errors as events but does NOT
  /// throw out of the outer generator, which previously caused later
  /// phases to plow ahead on null-binary state.
  @override
  Stream<InstallEvent> install() async* {
    // Phase 1: tarball download + extract. The installer emits
    // OllamaInstallEvents — convert: events with total bytes become
    // progress-bar updates (don't spam the log), others become log
    // lines.
    await for (final ev in installer.install()) {
      yield _toInstallEvent(ev);
    }
    yield const InstallEvent.log('Starting Ollama daemon…');
    final host = await installer.ensureDaemonRunning();
    yield InstallEvent.log('Daemon ready at $host.');
    // Persist where the daemon ended up so LlmClient can talk to it.
    final cfg = EnvConfig.load();
    if ((cfg.get('LLM_OLLAMA_HOST') ?? '') != host) {
      cfg.set('LLM_OLLAMA_HOST', host);
      await cfg.save();
    }
    await for (final ev in _ollamaPull(_inferenceModel(), host: host)) {
      yield ev;
    }
    await for (final ev in _ollamaPull(_embedModel, host: host)) {
      yield ev;
    }
    if (which('pdftotext') == null) {
      yield const InstallEvent.log(
        'Note: pdftotext (poppler-utils) is not installed. PDF '
        'documents will be skipped during RAG indexing; .txt / .md '
        '/ source files still work. Install via your package manager '
        '(`apt install poppler-utils`, `dnf install poppler-utils`, '
        '`brew install poppler`) and re-run to enable PDF support.',
      );
    } else {
      yield const InstallEvent.log('pdftotext detected.');
    }
    yield const InstallEvent.log('All set.');
  }

  /// Pull an additional inference model without touching anything else
  /// (no Ollama-binary install, no daemon restart, no embedding-model
  /// pull, no `LLM_MODEL` config change). Used by the "Install another
  /// model" affordance in System Settings → Modules so a user with
  /// gemma4:e4b already installed can add gemma4:12b for occasional
  /// heavier runs without going through the full install dance.
  ///
  /// The caller is responsible for ensuring the daemon is up — calling
  /// this on an uninstalled module will yield an error event from
  /// `_ollamaPull` when `resolveBinary` returns null.
  Stream<InstallEvent> pullAdditionalModel(String tag) async* {
    final host = _ollamaHost();
    await for (final ev in _ollamaPull(tag, host: host)) {
      yield ev;
    }
  }

  /// List inference model tags currently registered with the managed
  /// Ollama daemon. Filters out the embedding model — callers want
  /// what's usable as the hook-gen LLM. Returns an empty list when
  /// Ollama isn't installed or the daemon isn't responding (UI
  /// surfaces this as "no models installed yet").
  Future<List<String>> installedInferenceModels() async {
    final ollama = installer.resolveBinary();
    if (ollama == null) return const [];
    final host = _ollamaHost();
    if (!installer.isSystemInstall) {
      try {
        await installer.ensureDaemonRunning();
      } catch (_) {
        return const [];
      }
    }
    try {
      final r = await Process.run(
        ollama,
        ['list'],
        environment: {
          ...Platform.environment,
          'OLLAMA_HOST': host,
        },
      );
      final lines = (r.stdout as String).split('\n').skip(1);
      final tags = <String>[];
      for (final l in lines) {
        final tag = l.trim().split(RegExp(r'\s+')).firstOrNull ?? '';
        if (tag.isEmpty) continue;
        if (_tagMatches(tag, _embedModel)) continue;
        tags.add(tag);
      }
      return tags;
    } catch (_) {
      return const [];
    }
  }

  /// Bridge [OllamaInstallEvent] (orchestrator domain) into
  /// [InstallEvent] (UI contract). Events with bytes-known become
  /// progress-bar updates ONLY (no log spam); events without become
  /// plain log lines.
  static InstallEvent _toInstallEvent(OllamaInstallEvent ev) {
    final total = ev.total;
    final done = ev.done;
    if (total != null && done != null && total > 0) {
      return InstallEvent.progress(done / total, ev.message);
    }
    return InstallEvent.log(ev.message);
  }

  /// Pull an Ollama model. Routed via the installer-selected host so
  /// a user-local daemon (on 11435) gets the pull instead of any
  /// unrelated system Ollama on 11434.
  ///
  /// `ollama pull` does in-place CR updates even when piped; we split
  /// each \n-terminated logical line at the last `\r` so the final
  /// state of each phase is what we render (instead of every
  /// percentage tick separately). Lines containing a "N%" match drive
  /// the progress bar; phase-header lines without a percentage become
  /// log entries.
  Stream<InstallEvent> _ollamaPull(String tag, {required String host}) async* {
    final ollama = installer.resolveBinary()!;
    yield InstallEvent.log('Pulling "$tag"…');
    final proc = await Process.start(
      ollama,
      ['pull', tag],
      environment: {
        ...Platform.environment,
        'OLLAMA_HOST': host,
      },
    );
    final lines = StreamController<String>();
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onError: lines.addError);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onError: lines.addError);
    unawaited(proc.exitCode.then((_) => lines.close()));
    final percentRe = RegExp(r'(\d+(?:\.\d+)?)\s*%');
    // CSI escape sequence — `ESC [ … <final>`. Ollama emits these
    // (cursor moves, clear-line, hide/show cursor, synchronized
    // output mode) even when piped, which spammed the install log
    // until we started stripping them here.
    final ansiRe = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
    // The 8 standard Braille-pattern spinner frames plus the full
    // Braille range. Animation noise; nothing to log.
    final spinnerRe = RegExp('[⠀-⣿]');
    // Progress-bar block characters (the textual bar Ollama draws).
    final barRe = RegExp('[▏▎▍▌▋▊▉█▕]');
    String? lastLoggedHeader;
    await for (final raw in lines.stream) {
      // CR-collapsed line: take the segment after the last \r so we
      // only see the final state of any in-place-updated phase.
      final crCollapsed = raw.contains('\r') ? raw.split('\r').last : raw;
      // Strip terminal control noise before any matching.
      final cleaned = crCollapsed
          .replaceAll(ansiRe, '')
          .replaceAll(spinnerRe, '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned.isEmpty) continue;
      final m = percentRe.firstMatch(cleaned);
      if (m != null) {
        final pct = double.tryParse(m.group(1)!);
        if (pct != null) {
          // Also strip the bar glyphs from the label so the caption
          // is just "pulling <digest>: 23%  450 MB / 1.9 GB" or so.
          final label = cleaned.replaceAll(barRe, '').trim();
          yield InstallEvent.progress(pct / 100.0, label);
          continue;
        }
      }
      // Phase headers ("pulling manifest", "verifying digest", etc.)
      // — log once each, dedupe consecutive duplicates.
      if (cleaned != lastLoggedHeader) {
        lastLoggedHeader = cleaned;
        yield InstallEvent.log(cleaned);
      }
    }
    final code = await proc.exitCode;
    if (code != 0) {
      throw ComponentInstallException(
        '`ollama pull $tag` exited with code $code',
      );
    }
    yield InstallEvent.log('"$tag" ready.');
  }

  /// `t1` matches `t2` even if one of them omits the explicit `:latest` tag
  /// suffix that `ollama list` shows.
  static bool _tagMatches(String t1, String t2) {
    String norm(String t) => t.contains(':') ? t : '$t:latest';
    return norm(t1) == norm(t2);
  }
}

/// Memory-map initialization module (pure-Dart; gates the memory-map picker in
/// Synthesize and defines the constants/regions applied to a fresh machine).
class MemoryMapComponent extends Component {
  @override
  String get id => 'memory_map';
  @override
  String get title => 'Memory Map Initialization';
  @override
  String get description =>
      'Apply a memory-map (constants/regions) snapshot before emulation.';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_MEMORY_MAP';
  @override
  bool get installable => false;

  @override
  Future<ComponentStatus> detect() async =>
      const ComponentStatus(true, 'Built-in');

  @override
  Stream<InstallEvent> install() async* {
    yield const InstallEvent.log('Enabled.');
  }
}

/// Ghidra Analysis module — provides function-signature extraction
/// (per-symbol return type + parameter list + ABI-resolved argument
/// register/stack locations) and an enriched call-graph view.
///
/// This is a sibling of [LlmHookGenComponent], not a sub-phase: the
/// LLM module + Ghidra module are independently installable. With
/// Ghidra installed:
///   - `SignaturesService` can populate the prompt's `## Target →
///     Arguments` block with real per-function ABI mappings, so the
///     LLM doesn't have to guess which register holds which arg.
///   - The Call Graph tab can show typed signatures
///     (`int HAL_GetTick(void)`) instead of just names.
///
/// Without Ghidra installed, both consumers fall back gracefully:
/// the LLM uses generic AAPCS background, and the call graph stays
/// name-only — exactly today's behaviour.
class GhidraComponent extends Component {
  GhidraComponent({GhidraInstaller? installer})
      : installer = installer ?? GhidraInstaller();

  final GhidraInstaller installer;

  @override
  String get id => 'ghidra';
  @override
  String get title => 'Ghidra Analysis';
  @override
  String get description =>
      'Function signatures, ABI argument mappings, and enriched '
      'call-graph extraction via Ghidra headless analysis.';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_GHIDRA';
  @override
  bool get installable => true;

  @override
  Future<ComponentStatus> detect() async {
    // Java is checked AT INSTALL TIME, not detect — if no system
    // Java is present, the installer downloads a Temurin JRE under
    // its managed root, so detect just needs to verify Ghidra and
    // any prereqs are present *after* install. If install hasn't
    // run, the missing JRE is reported as part of "Ghidra not
    // installed" since the user gets the same Install button
    // either way.
    final dir = installer.resolveInstallDir();
    if (dir == null) {
      return const ComponentStatus(false, 'Ghidra not installed');
    }
    final java = await installer.resolveJavaBinary();
    if (java == null) {
      return const ComponentStatus(
        false,
        'Ghidra installed but no Java 21+ — re-run install',
      );
    }
    return ComponentStatus(true, 'Ready — $dir');
  }

  @override
  Stream<InstallEvent> install() async* {
    await for (final ev in installer.install()) {
      final total = ev.total;
      final done = ev.done;
      if (total != null && done != null && total > 0) {
        yield InstallEvent.progress(done / total, ev.message);
      } else {
        yield InstallEvent.log(ev.message);
      }
    }
  }
}

/// Communication-bus virtualization module (gates the Comms tab where I2C/SPI/
/// UART functions are mapped to software implementations).
class CommsBusComponent extends Component {
  @override
  String get id => 'comms_bus';
  @override
  String get title => 'Communication Bus Virtualization';
  @override
  String get description =>
      'Map I2C/SPI/UART functions to software implementations (Comms tab).';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_COMMS_BUS';
  @override
  bool get installable => false;

  @override
  Future<ComponentStatus> detect() async =>
      const ComponentStatus(true, 'Built-in');

  @override
  Stream<InstallEvent> install() async* {
    yield const InstallEvent.log('Enabled.');
  }
}

/// The v1 optional-module registry. The Riverpod layer passes
/// long-lived installer singletons in so we don't orphan their
/// background state (Ollama's spawned daemon handle, Ghidra's
/// install-progress streams, etc.) every time the registry is
/// rebuilt (e.g. when `componentStatusProvider` re-detects).
List<Component> buildComponentRegistry({
  OllamaInstaller? installer,
  GhidraInstaller? ghidraInstaller,
}) =>
    [
      LlmHookGenComponent(installer: installer),
      GhidraComponent(installer: ghidraInstaller),
      MemoryMapComponent(),
      CommsBusComponent(),
    ];
