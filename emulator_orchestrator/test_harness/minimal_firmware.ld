/* Minimal Cortex-M4 linker script for the hook test harness. */

MEMORY
{
  flash (rx) : ORIGIN = 0x00000000, LENGTH = 0x1000
  sram  (rwx): ORIGIN = 0x20000000, LENGTH = 0x1000
}

ENTRY(Reset_Handler)

SECTIONS
{
  .vectors : { KEEP(*(.vectors)) } > flash

  .text : {
    *(.text*)
    *(.rodata*)
  } > flash

  /* SRAM layout: results[10] (40B) + done_flag (4B) first, so their
     addresses are known up front (0x20000000 and 0x20000028). The
     harness reads results from 0x20000000.
     Note: linker sorts .bss symbols alphabetically by default within
     a section. We use explicit subsections (.bss.results,
     .bss.done_flag) and order them here. */
  .bss : {
    *(.bss.results)
    *(.bss.done_flag)
    *(.bss*)
    *(COMMON)
  } > sram

  /* Stack grows down from the top of SRAM. */
  _stack_top = ORIGIN(sram) + LENGTH(sram);
}
