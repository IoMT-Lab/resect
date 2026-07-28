/// Per-task LLM tuning profiles — the single place every gemma
/// sampling/think/budget knob lives.
///
/// Before this existed, each service hardcoded its own params inline
/// (temp/think/numPredict scattered across `RecommendationService`,
/// `LastRunInsightService`, `LlmJudge`, `LlmHookGenerator`), which is
/// how the loop ended up running the *creative* recipe (temp 1.0 +
/// unbounded thinking) on what are actually *decisions* — the primary
/// driver of the thinking-spiral recursion. Collecting the knobs here
/// makes the policy auditable at a glance and keeps "decisions run
/// think-off/temp-0" a one-line invariant rather than a convention.
///
/// What a profile does NOT carry:
///   - `format` (the JSON schema for constrained decoding) is built
///     dynamically per call from the live catalog/frontier, so it's
///     supplied at the call site, not here.
///   - `stop` sequences are intrinsic to a specific prompt's failure
///     mode (hook-gen's comment-preamble stops), so they stay with
///     that caller.
///   - The concrete model tag: `modelPolicy` names the selection
///     rule; resolving it needs a live `listModels()` call the
///     profile can't make.
library;

/// How a profile picks which installed model to run against.
enum LlmModelPolicy {
  /// Use the constructor-configured `LlmClient.model` tag.
  configured,

  /// Use the smallest installed model (`listModels().first`),
  /// falling back to the configured tag when `/api/tags` is
  /// unreachable. Only the advisor uses this — its output is 1–3
  /// sentences, so a 1B-param model is plenty and runs an order of
  /// magnitude faster.
  smallestInstalled,
}

/// Static sampling/think/budget policy for one LLM task.
class LlmProfile {
  const LlmProfile({
    required this.think,
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.numCtx,
    required this.numPredict,
    required this.modelPolicy,
    this.watchdogThinkChunks,
  });

  /// Whether Gemma's thinking channel is enabled. Gemma thinking is
  /// boolean on/off only (no budget lever exists upstream), so this
  /// is THE anti-recursion knob: every decision task sets it false.
  final bool think;

  final double temperature;
  final double topP;
  final int topK;
  final int numCtx;

  /// Output-token budget. Note Ollama counts thinking tokens toward
  /// this, so a think-on profile must leave headroom (or rely on the
  /// watchdog) — a think-off profile spends the whole budget on the
  /// answer.
  final int numPredict;

  final LlmModelPolicy modelPolicy;

  /// Number of thinking chunks that, with zero response tokens yet,
  /// trips the client-side watchdog to cancel and retry once with a
  /// narrower scaffold. Null = no watchdog (only meaningful on a
  /// think-on profile; every other profile eliminates recursion
  /// structurally by disabling thinking).
  final int? watchdogThinkChunks;
}

/// The task profiles. See `radiant-inventing-dream.md` §A for the
/// rationale table.
abstract final class LlmProfiles {
  /// Job 2 — proactive coverage recommendation. A pick-from-catalog
  /// decision emitted as schema-constrained JSON; no reasoning
  /// needed, so think-off/temp-0 both eliminates the spiral and
  /// (per Ollama's structured-output guidance) is the recommended
  /// setting for JSON.
  static const job2Coverage = LlmProfile(
    think: false,
    temperature: 0.0,
    topP: 0.95,
    topK: 64,
    numCtx: 16384,
    // 1600, not 1024: the schema allows up to 10 recommendations
    // (batch classification of a frontier), and 10 entries + rationales
    // + prose overflow a 1024-token budget — truncated JSON parses as
    // malformedJson and kills a headless session. Not higher either:
    // on a CPU-bound host (12B doesn't fit consumer VRAM) generation
    // runs at ~1-3 tok/s, so the budget IS the worst-case round time —
    // 3072 was observed grinding for 40 minutes. A typical valid
    // 10-rec batch is ~1000 tokens; 1600 leaves headroom.
    numPredict: 1600,
    modelPolicy: LlmModelPolicy.configured,
  );

  /// Job 1 stage 1 — authorship shape selection. Pick one of a
  /// handful of named hook shapes + scalar params via schema. A
  /// decision, not a derivation → think-off.
  static const job1Triage = LlmProfile(
    think: false,
    temperature: 0.0,
    topP: 0.95,
    topK: 64,
    numCtx: 16384,
    numPredict: 512,
    modelPolicy: LlmModelPolicy.configured,
  );

  /// Job 1 stage 2 — hook body authorship. The ONLY think-on
  /// profile: in-house verification (2026-06-11) found thinking
  /// necessary to fill in the canonical out-pointer shape on
  /// gemma4:e4b. Model-card sampling (temp 1.0/.95/64). Backstopped
  /// by the watchdog since Gemma thinking is uncappable.
  static const authorship = LlmProfile(
    think: true,
    temperature: 1.0,
    topP: 0.95,
    topK: 64,
    numCtx: 16384,
    numPredict: 4000,
    modelPolicy: LlmModelPolicy.configured,
    watchdogThinkChunks: 1500,
  );

  /// Advisor — Last Run card prose (1–3 sentences). Think-off; runs
  /// on the smallest installed model.
  static const advisor = LlmProfile(
    think: false,
    temperature: 0.0,
    topP: 0.95,
    topK: 64,
    numCtx: 16384,
    numPredict: 384,
    modelPolicy: LlmModelPolicy.smallestInstalled,
  );

  /// Judge — hook A/B verdict. Already think-off/temp-0 before this
  /// registry existed; folded in verbatim, gains a verdict schema at
  /// the call site.
  static const judge = LlmProfile(
    think: false,
    temperature: 0.0,
    topP: 0.95,
    topK: 64,
    numCtx: 16384,
    numPredict: 256,
    modelPolicy: LlmModelPolicy.configured,
  );
}
