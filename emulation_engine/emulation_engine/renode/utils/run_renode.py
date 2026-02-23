import asyncio
import os

from ..renode import Renode

async def aprint(msg):
    print(msg)

async def main():
    path = os.getenv('RENODE_EXECUTABLE', 'renode')
    port = os.getenv('RENODE_PORT', 5000)

    print(f'Starting Renode with:\n\texe={path}\n\tport={port}')
    renode = Renode(path)

    renode.emit_started_event = lambda: aprint('Emulation started')
    renode.emit_paused_event = lambda user, symbol, symbol_unknown: aprint(f'Emulation paused (user={user}, symbol={symbol}, symbol_unknown={symbol_unknown})')
    renode.emit_resumed_event = lambda: aprint('Emulation resumed')
    renode.emit_reset_event = lambda: aprint('Emulation reset')
    renode.emit_unknown_symbol_event = lambda symbol: aprint(f'Unknown symbol: {symbol}')
    renode.emit_trace_event = lambda symbol, entry: aprint(f'{"Entering" if entry else "Exiting"} function: {symbol}')
    await renode.start(port, output=True)
    print('Renode started')

    await renode.load('@platforms/cpus/stm32wb05_empty.repl', '"/home/taylor/workspace/vanderbilt/projects/upgrade/engine/aya_ppg.elf"')
    await renode.run(None, None, ['SystemInit'], False)
    await renode.process_events()

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print('Exiting program')