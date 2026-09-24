# Chip Corpus: Vendor SDKs and Docs for Synthesis {#chip_corpus}

Synthesis and [auto-tune](@ref autotune) reason about firmware with no
built-in knowledge of the target MCU. The **chip corpus** closes that
gap: Resect detects the processor, fetches the manufacturer's SDK,
register maps (SVD), and datasheets, embeds them into a shared cache,
and injects the relevant pieces into the retrieval-augmented prompts
that drive hook generation and the auto-tune advisor.

Everything is **manual** — nothing downloads until you ask — and the
cache is **shared per chip family**, so a second project on the same MCU
reuses it instantly.

## The three stages

1. **Detect.** `ChipDetector`
   (`emulator_orchestrator/lib/services/chip/chip_detector.dart`) reads,
   in priority order: an `ApplySVD @<url>` line in the platform `.repl`
   (names the exact part and hands over a register-map URL); a
   fingerprint match against the Renode-bundled part-named platform
   files (`PlatformIndex`); a part-shaped token in the repl/ELF
   filename; and vendor-prefixed firmware symbols (`HAL_`/`LL_` → ST,
   `nrf_`/`nrfx_` → Nordic). The result is a `ChipIdentity`
   (vendor/family/part/core + confidence + evidence), persisted on the
   project as `metadata['chip_identity']`. A user override wins and is
   never re-clobbered.

2. **Fetch.** A curated `VendorCorpusAdapter` turns the identity into a
   `FetchPlan` — a pure list of pinned URLs with kinds, sizes, and
   license notes. The plan is what you consent to (CLI prompt or UI
   dialog); the fetcher downloads it with `dart:io` and extracts the
   glob-kept SDK subtrees with `package:archive` (no `git`/`unzip`
   needed). SVDs are distilled to one text block per peripheral;
   SDK source/headers are chunked with a provenance header; PDFs go
   through `pdftotext`.

3. **Retrieve.** The corpus lives in its own versioned sqlite
   (`<config>/corpus/<vendor.family>/corpus.db`) with SQL-side
   prefiltering (kind + part + FTS terms, capped) so retrieval stays
   fast at tens of thousands of chunks. `LlmHookGenerator` and
   `RecommendationService` query it through the shared `Retriever`
   interface and render the hits as a `## Chip SDK context` /
   `### Chip reference` section — additive to the project context, never
   replacing it.

## Driving it

### CLI (headless, both commands)

    resect-cli corpus detect --emu <project.emu>
    resect-cli corpus fetch  --chip STM32WB05          # prints the plan, prompts
    resect-cli corpus fetch  --chip STM32WB05 --yes    # non-interactive consent
    resect-cli corpus status --chip STM32WB05

`synthesize` and `autotune` take `--chip <part>` (override detection) and
`--fetch-corpus` (detect → consent → fetch → run, one command):

    resect-cli autotune --emu p.emu --fetch-corpus --yes --max-rounds 1
    resect-cli synthesize --elf f.elf --repl f.repl --chip STM32WB05

Without `--yes` on a non-TTY the fetch declines cleanly before any
download. Both commands run project-only retrieval when no corpus
exists, printing a hint.

### UI

The **CHIP CORPUS** card on the Library tab shows the detected MCU and
corpus status; **Fetch** opens a consent dialog listing each item with
its size and license, then streams progress. Once fetched, the Synthesize
tab's runs and auto-tune sessions pick up the corpus automatically.

## Adding a vendor

One adapter file under
`emulator_orchestrator/lib/services/corpus/adapters/` implementing
`VendorCorpusAdapter` (a pure `plan(ChipIdentity)` over curated static
tables), one line in `vendor_adapter_registry.dart`, a golden-plan
fixture, and a detection fixture. v1 ships ST; Nordic follows the same
shape (its nrfx tarball bundles the SVDs).

## Storage and licensing

The cache sits under `configDir` (persists in the docker resect-state
volume). It is a **local** copy of vendor-published material for
synthesis reference only — Resect never redistributes it. Each item
records its license note; datasheet PDFs are optional and, when a
curated URL is unavailable, you can drop a PDF into the corpus's
`drop_in/` folder to have it ingested.
