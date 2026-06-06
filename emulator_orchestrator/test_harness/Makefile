# Build the minimal Cortex-M4 firmware used by the hook test harness.
#
# Requires `arm-none-eabi-gcc` (binutils + gcc). The committed
# `minimal_firmware.elf` is the canonical artifact — only rebuild
# when `minimal_firmware.c` or `minimal_firmware.ld` change.
#
# Targets:
#   make            -> build minimal_firmware.elf
#   make regen-dart -> rebuild ELF and regenerate the embedded Dart
#                      constants in lib/data/services/test_harness_assets.dart
#   make clean      -> remove build artifacts

CC      := arm-none-eabi-gcc
OBJCOPY := arm-none-eabi-objcopy
OBJDUMP := arm-none-eabi-objdump

CFLAGS := \
  -mcpu=cortex-m4 \
  -mthumb \
  -nostdlib \
  -nostartfiles \
  -ffreestanding \
  -fno-builtin \
  -Os \
  -Wall \
  -Wextra \
  -std=c11

LDFLAGS := \
  -T minimal_firmware.ld \
  -Wl,--gc-sections \
  -Wl,--no-warn-rwx-segments

ELF := minimal_firmware.elf

.PHONY: all clean regen-dart inspect

all: $(ELF)

$(ELF): minimal_firmware.c minimal_firmware.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ minimal_firmware.c

inspect: $(ELF)
	@echo '--- symbols of interest ---'
	@$(OBJDUMP) -t $(ELF) | grep -E ' (main|halt_loop|Reset_Handler|results|done_flag|vector_table)$$' || true
	@echo
	@echo '--- size ---'
	@ls -l $(ELF)
	@echo
	@echo '--- sections ---'
	@$(OBJDUMP) -h $(ELF) | grep -E '^\s+[0-9]+ \.(text|vectors|bss|rodata)'

regen-dart: $(ELF)
	cd .. && dart run tool/gen_test_harness_assets.dart

clean:
	rm -f $(ELF) *.o *.bin
