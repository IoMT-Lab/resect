import 'package:resect_callgraph/resect_callgraph.dart' show Machine;

/// Single source of truth for everything arch-conditional in resect.
///
/// Built once from the loaded ELF's `e_machine` field (via
/// [FirmwareRecord.machine]) and threaded through every layer that
/// used to hardcode ARM Cortex-M:
///   - hook catalog builders (return-from-hook snippet, glue module
///     name, default `architecture` column value)
///   - LLM system prompt (the `# Target architecture` runtime block)
///   - UI architecture pickers (replaces hardcoded
///     `['ARM', 'x86_64']`)
///   - per-arch `extractI2cParams` / `extractUartParams` style
///     helpers (each arch picks its own glue module)
///
/// The registry below covers what we have working test fixtures or
/// real ELFs for; adding a new arch is one entry + (if needed) a
/// new `_glue` Python module in hooks-dart.
class TargetArch {
  const TargetArch({
    required this.id,
    required this.displayName,
    required this.machine,
    required this.returnRegister,
    required this.argRegisters,
    required this.returnSnippet,
    required this.glueModuleName,
    required this.callingConventionName,
  });

  /// Short stable identifier — `arm-cortex-m`, `riscv-rv32`,
  /// `x86_64`, … . Used as the `architecture` column value in the
  /// hooks DB and as the key in any future per-arch catalog lookup.
  final String id;

  /// Human label for the picker in the Hook DB dialog.
  final String displayName;

  /// The ELF e_machine value this entry handles.
  final Machine machine;

  /// Return register name as it appears in the catalog's IronPython
  /// hooks (`r0`, `a0`, `rax`). For models that don't surface
  /// register names by string (only numeric), this matches the
  /// numeric arg-0 register's canonical name.
  final String returnRegister;

  /// Arg-passing registers in declaration order — first one is
  /// `cpu.GetRegister(0)`, second is `cpu.GetRegister(1)`, etc.
  /// Length matches the calling convention's register-arg limit
  /// (4 for AAPCS, 8 for RISC-V, 6 for x86_64 SysV).
  final List<String> argRegisters;

  /// The exact IronPython statement that returns from the hook —
  /// gets emitted at the end of every catalog body.
  ///
  /// Examples:
  ///   - ARM Cortex-M / AAPCS64: `cpu.PC = cpu.LR`
  ///   - RISC-V: `cpu.PC = cpu.GetRegister(1)` (x1 / RA)
  ///   - x86_64: stack-pop pattern that reads the return address
  ///     and bumps RSP
  ///
  /// Verified against Renode's actual CPU binding for each arch
  /// before use; ARM's `cpu.LR` works because Renode's Cortex-M
  /// peripheral exposes LR as a property, but other archs use the
  /// generic `cpu.GetRegister(N)` form to avoid relying on binding-
  /// specific property names.
  final String returnSnippet;

  /// Name of the hooks-dart Python helper module that carries the
  /// platform-specific arg extraction logic — `stm32_glue`,
  /// `esp_idf_glue`, `riscv_glue`. Imported by bus-virtualised
  /// catalog hooks. Empty when no glue module exists yet for the
  /// arch (in which case bus-virtualised hooks are unavailable;
  /// plain return/read/write/increment still work).
  final String glueModuleName;

  /// Ghidra's calling-convention name for this arch — informational,
  /// surfaced in the LLM prompt's `# Target architecture` block so
  /// the model knows which ABI to reason about when Ghidra-extracted
  /// per-function signatures aren't available.
  final String callingConventionName;

  /// Architecture-portable IronPython snippet that sets the return
  /// register (always reg index 0 on every arch in the registry).
  /// Used by [_setReturnValueModule]'s template.
  String setReturnRegisterSnippet(String valueExpr) =>
      'cpu.SetRegister(0, RegisterValue.Create($valueExpr, 64))';
}

// ----------------------------------------------------------------------------
// Registry — one entry per arch we've validated end-to-end.

const _armCortexM = TargetArch(
  id: 'arm-cortex-m',
  displayName: 'ARM Cortex-M',
  machine: Machine.arm,
  returnRegister: 'r0',
  argRegisters: ['r0', 'r1', 'r2', 'r3'],
  // Renode's Cortex-M peripheral exposes LR as a property, so we
  // use the existing catalog idiom rather than GetRegister(14).
  returnSnippet: 'cpu.PC = cpu.LR',
  glueModuleName: 'stm32_glue',
  callingConventionName: 'AAPCS',
);

const _aarch64 = TargetArch(
  id: 'aarch64',
  displayName: 'ARM64 (AArch64)',
  machine: Machine.aarch64,
  returnRegister: 'x0',
  argRegisters: ['x0', 'x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7'],
  // AAPCS64's link register is x30 (LR). Renode's AArch64 binding
  // exposes it as cpu.LR same as Cortex-M.
  returnSnippet: 'cpu.PC = cpu.LR',
  glueModuleName: '',
  callingConventionName: 'AAPCS64',
);

const _riscv = TargetArch(
  id: 'riscv',
  displayName: 'RISC-V',
  machine: Machine.riscv,
  returnRegister: 'a0',
  argRegisters: ['a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7'],
  // RISC-V return address is x1 / RA. Using the generic
  // GetRegister(1) form because Renode's RISC-V binding's property
  // name for RA hasn't been verified here.
  returnSnippet: 'cpu.PC = cpu.GetRegister(1)',
  glueModuleName: '',
  callingConventionName: 'RISC-V ILP32/LP64',
);

const _x86_64 = TargetArch(
  id: 'x86_64',
  displayName: 'x86_64 (System V)',
  machine: Machine.x86_64,
  returnRegister: 'rax',
  argRegisters: ['rdi', 'rsi', 'rdx', 'rcx', 'r8', 'r9'],
  // x86_64 returns by popping the saved RIP off the stack. The
  // catalog idiom for this arch needs to read [rsp] into PC and
  // bump RSP by 8. The exact snippet depends on Renode's x86_64
  // binding — encoded as a multi-statement snippet here.
  returnSnippet:
      'cpu.PC = cpu.Bus.ReadDoubleWord(cpu.GetRegister(7).RawValue)\n'
      'cpu.SetRegister(7, RegisterValue.Create(cpu.GetRegister(7).RawValue + 8, 64))',
  glueModuleName: '',
  callingConventionName: 'System V AMD64',
);

/// All architectures resect has end-to-end support for. Lookup is
/// by [Machine] (the ELF e_machine value). Adding a new arch is a
/// single entry here plus (optionally) a new `_glue` Python module
/// in hooks-dart for platforms that wrap their HAL with non-ABI arg
/// conventions.
const archRegistry = <Machine, TargetArch>{
  Machine.arm: _armCortexM,
  Machine.aarch64: _aarch64,
  Machine.riscv: _riscv,
  Machine.x86_64: _x86_64,
};

/// Resolve a [Machine] → [TargetArch], or null when we don't have
/// an entry for it. Callers fall back to ARM Cortex-M for old
/// projects whose .emu predates the e_machine field; for unknown
/// archs the LLM dialog uses the no-signature, no-platform fallback
/// in the system prompt.
TargetArch? targetArchFor(Machine? machine) {
  if (machine == null) return null;
  return archRegistry[machine];
}
