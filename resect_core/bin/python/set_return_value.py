def setReturnValue(cpu, value):
    from Antmicro.Renode.Peripherals.CPU import RegisterValue # type: ignore
    cpu.SetRegister(0, RegisterValue.Create(value, 64))
    cpu.PC = cpu.LR