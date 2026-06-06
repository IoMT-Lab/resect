# Hook test harness fixtures

This directory contains the minimal firmware and Renode platform used by
the in-app Hook Test Harness. The harness spins up a fresh Renode
machine, loads the bundled firmware, applies the hook under test to the
firmware's `main` symbol, runs the machine, and reports what each call
to `main` returned.

## Files

| Path | Purpose |
|---|---|
| `minimal_firmware.c` | Bootstrap: calls `main()` 10× in a loop, stores each return value into `results[]` at `0x20000000`, then spins in `halt_loop`. |
| `minimal_firmware.ld` | Linker script. Flash at `0x00000000`, SRAM at `0x20000000`. Pins `results[]` to the start of SRAM. |
| `minimal_firmware.elf` | Pre-built ELF (~2 KB). Committed so users without `arm-none-eabi-gcc` don't need to build anything. |
| `minimal_cortex_m.repl` | Minimal Cortex-M4 Renode platform: CPU + NVIC + 4 KB flash + 4 KB SRAM. No peripherals. |
| `Makefile` | Build targets. |

## Rebuilding

Only needed when `minimal_firmware.c` or `minimal_firmware.ld` change.
Requires `arm-none-eabi-gcc` on PATH.

```
make            # rebuilds minimal_firmware.elf
make inspect    # prints symbol addresses + sections (sanity check)
make regen-dart # rebuilds ELF and regenerates the embedded Dart
                # constants in lib/data/services/test_harness_assets.dart
make clean
```

Commit both `minimal_firmware.elf` and the regenerated Dart constants.

## How the harness uses these

At runtime, `HookTestHarness` doesn't read these files from disk. The
codegen script (`tool/gen_test_harness_assets.dart`) base64-encodes
the `.elf` and `.repl` into Dart string constants in
`lib/data/services/test_harness_assets.dart`, alongside the symbol
addresses extracted from the ELF (`mainSymbol`, `haltLoopAddr`,
`resultsAddr`). The harness loads from those constants — no
filesystem dependency, works in AOT Flutter builds.

## How the harness exercises hooks

1. Fresh `DartEngine` spawned on port 5099.
2. `controller.load` with the embedded `.repl` + `.elf`.
3. `controller.defineHook` + `controller.mapHooks({'main': ...})`.
4. `controller.start` → bootstrap runs.
5. Bootstrap calls `main` 10 times. Each call lands in the user's
   hook (because of `AddHookAtSymbol "main"`). The hook puts a return
   value in R0 and jumps to LR.
6. Bootstrap stores R0 into `results[i]`, repeats.
7. After 10 iterations, bootstrap sets `done_flag = 1` and enters
   `halt_loop`.
8. Harness watches PC reach `halt_loop` (via another hook), pauses,
   reads `results[0..9]` via `readMemory`, tears down.
