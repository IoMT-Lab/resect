# RETAINED — NOT USED BY THE APP. Part of the legacy Python emulation engine,
# superseded by the in-process Dart engine (renode-dart + callgraph-dart). Kept
# only because this dir also holds the still-used Renode binary and the Vagrant
# CI harness still provisions it. See emulation_engine/engine.py for details.

from emulation_engine.memory import Snapshot
from emulation_engine.transport.client import Client

async def atrace(symbol, entry):
    print(f"Trace: {symbol} ({'entry' if entry else ''})")

async def aunhandled_access(symbol, program_counter, address, width_in_bytes, is_write, value):
    print(f"Unhandled access at symbol: {symbol}, PC: {hex(program_counter)}, address: {hex(address)}, width: {width_in_bytes} bytes, is_write: {is_write}, value: {hex(value)}")

async def main():
    async with Client() as client:
        client.trace.handle_trace = atrace
        client.lifecycle.handle_unhandled_access = aunhandled_access
        async def on_paused(user, symbol, unhandled_access):
            print(f"Emulation paused. User: {user}, Symbol: {symbol}, Unhandled Access: {unhandled_access}")
            if unhandled_access:
                if symbol == 'SystemInit':
                    # await client.console.call_command('sysbus.cpu Step')
                    await client.lifecycle.call_resume()

        client.lifecycle.handle_paused = on_paused
        await client.connect('http://localhost:12356')
        await client.lifecycle.call_reset()
        # print(await client.callgraph.call_get_symbols('/home/taylor/workspace/vanderbilt/projects/upgrade/aya-emulator/emulator/firmware/aya_ppg.elf'))
        # print(await client.callgraph.call_get_callgraph('/home/taylor/workspace/vanderbilt/projects/upgrade/aya-emulator/emulator/firmware/aya_ppg.elf'))
        await client.lifecycle.call_load('@platforms/cpus/stm32wb05_empty.repl', '"/home/taylor/workspace/vanderbilt/projects/upgrade/aya-emulator/emulator/firmware/aya_ppg.elf"')
        
        await client.lifecycle.call_define_hook('return_0','''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(0, 64))
cpu.PC = cpu.LR
print(cpu.PC)
''')

        await client.lifecycle.call_define_hook('return_1','''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(1, 64))
cpu.PC = cpu.LR
''')
        await client.lifecycle.call_map_hooks({
            'LL_RCC_HSE_IsReady':'return_1',
            'LL_RCC_LSI_IsReady':'return_0',
            'HAL_RCC_OscConfig':'return_0',
            'HAL_RCC_ClockConfig':'return_0',})
        
        await client.memory.call_read_registers()
        await client.memory.call_set_constant(0x48500014, 'SMPS', 4, 0xFF)
        
        snapshot = await client.memory.call_save({0x20000000: 0x100})
        print(snapshot.to_dict())

        print(await client.memory.call_read(0x20000000, 2))
        await client.memory.call_write(0x20000000, b'ff')
        print(await client.memory.call_read(0x20000000, 2))

        await client.memory.call_restore(snapshot)
        print(await client.memory.call_read(0x20000000, 2))


        await client.lifecycle.call_start('main', None, True)

        await client.wait()


if __name__ == '__main__':
    import asyncio
    asyncio.run(main())