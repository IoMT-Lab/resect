// Minimal Cortex-M4 firmware for hook testing.
//
// The test harness loads this ELF into a fresh Renode machine, applies the
// hook under test to `main`, runs the bootstrap below, and reads back the
// 10-entry `results[]` array via `client.readMemory` to see what the hook
// returned on each invocation.
//
// Hand-written `Reset_Handler` and vector table — no libc, no startup
// runtime. Keeps the binary small and predictable.
//
// Memory layout (see minimal_firmware.ld):
//   0x00000000  flash  : vector table + code
//   0x20000000  sram   : `results[]` (40 bytes) + `done_flag` (4 bytes)
//
// `Reset_Handler` calls main() ten times in a loop, stores each return
// value into `results[i]`, sets `done_flag = 1`, and spins forever in
// `halt_loop`. The harness uses `halt_loop`'s symbol address to detect
// "test complete" — install a Renode hook there that pauses the machine.

#include <stdint.h>

#define RESULTS_COUNT 10

// SRAM-resident. Named subsections so the linker can pin `results` at
// 0x20000000 and `done_flag` immediately after.
volatile uint32_t results[RESULTS_COUNT] __attribute__((section(".bss.results")));
volatile uint32_t done_flag __attribute__((section(".bss.done_flag")));

// Placeholder. The hook under test replaces this symbol's behavior in
// Renode via AddHookAtSymbol. With no hook applied, this just returns 0.
__attribute__((noinline, used))
int main(void) {
  return 0;
}

// Wait-here-when-done loop. The harness watches PC reach this address
// (looked up by symbol name `halt_loop` in the ELF symbol table) to know
// the bootstrap finished.
__attribute__((noinline, used))
void halt_loop(void) {
  while (1) { __asm__ volatile("nop"); }
}

__attribute__((noreturn, used))
void Reset_Handler(void) {
  // CRITICAL: call main() through a volatile function pointer so GCC
  // can't hoist the call out of the loop. Without this, the compiler
  // sees that `int main(void) { return 0; }` is pure and rewrites
  //   for (i = 0; i < 10; i++) results[i] = main();
  // into "bl main once; store r0 to all 10 results[i]". The hook
  // installed by the test harness then fires exactly once (because
  // PC only reaches main's address once), and the bootstrap stamps
  // that single return value into every slot. Stateful hooks look
  // like they aren't accumulating state, but actually they're just
  // never being re-entered.
  //
  // The `volatile` qualifier on the pointer forces GCC to reload it
  // every iteration (it could have been mutated by something the
  // compiler can't see). The reload makes the call indirect via the
  // pointer, which GCC won't hoist because it can't prove the pointer
  // still points at the same target. `static` keeps the pointer in
  // initialised data instead of on the stack.
  static int (* volatile main_ptr)(void) = main;
  for (uint32_t i = 0; i < RESULTS_COUNT; i++) {
    results[i] = (uint32_t)main_ptr();
  }
  done_flag = 1;
  halt_loop();
  __builtin_unreachable();
}

// Vector table at flash base. Cortex-M expects:
//   [0]  initial main stack pointer
//   [1]  reset handler address (Thumb bit set)
// Other entries (NMI, HardFault, etc.) point to a default trap so a
// fault doesn't silently jump to zero.
__attribute__((noreturn, used))
static void Default_Handler(void) {
  while (1) { __asm__ volatile("nop"); }
}

extern uint32_t _stack_top;

__attribute__((section(".vectors"), used))
void (* const vector_table[])(void) = {
  (void (*)(void)) &_stack_top,   // initial SP
  Reset_Handler,                   // reset
  Default_Handler,                 // NMI
  Default_Handler,                 // HardFault
  Default_Handler,                 // MemManage
  Default_Handler,                 // BusFault
  Default_Handler,                 // UsageFault
};
