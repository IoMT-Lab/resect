from typing import Coroutine, Callable, Any
import asyncio

from emulation_engine.memory import Snapshot

from .console_endpoint import ConsoleEndpoint
from .event_endpoint import EventEndpoint
from .logging_endpoint import LoggingEndpoint

import logging
logger = logging.getLogger(__name__)

class Renode:
    def __init__(self, renode_exec_path, logging_path):
        self.renode_exec_path = renode_exec_path
        self.proc = None
        self.console = None
        self.events = None
        self.logging = None

        self.logging_path = logging_path

        self.hooks = {}
        self.hook_map = {}

        self.started = False
        self.pending_pause = False
        self.last_symbol = None
        self.last_unhandled_symbol = None
        self.auto_restart_symbols = []
        self.delayed_task = None
        self._resetting = False

        self.emit_started_event: Callable[[], Coroutine[Any, Any, None]] | None  = None
        self.emit_paused_event: Callable[[bool, str | None, bool | None], Coroutine[Any, Any, None]] | None = None
        self.emit_resumed_event: Callable[[], Coroutine[Any, Any, None]] | None = None
        self.emit_unhandled_access_event: Callable[[str, int, int, int, bool, int], Coroutine[Any, Any, None]] | None = None
        self.emit_reset_event: Callable[[], Coroutine[Any, Any, None]] | None = None
        self.emit_trace_event: Callable[[str, bool], Coroutine[Any, Any, None]] | None = None

    async def start(self, port, output=False):
        logger.info(f"Starting Renode on port {port} with executable '{self.renode_exec_path}'")
        stdout = asyncio.subprocess.DEVNULL if not output else None
        self.proc = await asyncio.create_subprocess_exec(self.renode_exec_path, '-p', '--disable-gui', '--server-mode', '--server-mode-port', str(port), stdout=stdout)
        
        logger.debug("Renode process started, waiting for it to initialize...")
        await asyncio.sleep(5)  # Give Renode some time to start up and listen on the port

        log_filename = f'{self.logging_path}/renode.log'
        shell_filename = f'{self.logging_path}/renode_shell.log'
        self.logging = LoggingEndpoint('localhost', port, log_filename, shell_filename)
        try:
            await self.logging.connect()
            logger.info("LoggingEndpoint connected successfully")
        except Exception as e:
            logger.error(f"Failed to connect LoggingEndpoint: {e}")
            raise

        self.console = ConsoleEndpoint('localhost', port)
        try:
            await self.console.connect()
            logger.info("ConsoleEndpoint connected successfully")
        except Exception as e:
            logger.error(f"Failed to connect ConsoleEndpoint: {e}")
            raise

        self.events = EventEndpoint('localhost', port, ['emulation-state-changed', 'unhandled-access', 'function-call'])
        try:
            await self.events.connect()
            logger.info("EventEndpoint connected successfully")
        except Exception as e:
            logger.error(f"Failed to connect EventEndpoint: {e}")
            raise
        logger.info("Renode started and connected to endpoints.")

    async def call(self, command: str, *args):
        logger.debug(f"Calling command: {command} with arguments: {args}")
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        return await self.console.call(command, *args)

    async def wait(self):
        if self.proc:
            await self.proc.wait()

    async def restore(self, snapshot: Snapshot):
        logger.debug(f"Restoring snapshot")
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        
        await self.console.write_registers(snapshot.registers)
        for address, data in snapshot.memory.items():
            address = int(address)
            await self.console.write_memory(address, data)

    async def save(self, memory_regions: dict[int, int]) -> Snapshot:
        logger.debug(f'Saving snapshot for memory regions: {memory_regions}')
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        
        registers = await self.console.read_registers()
        
        memory = {}
        for address, size in memory_regions.items():
            address = int(address)
            memory[address] = await self.console.read_memory(address, size)

        return Snapshot(registers, memory)

    async def process_events(self):
        if not self.events:
            raise Exception("Renode is not running. Please start it first.")
        
        async for event in self.events:
            if event.name == 'emulation-state-changed':
                await self._process_emulation_state_changed(event.data)
            elif self._resetting:
                continue  # skip stale trace events while draining to emulation-cleared
            elif event.name == 'function-call':
                await self._process_function_call(event.data)
            elif event.name == 'unhandled-access':
                await self._process_unhandled_access(event.data)
            else:
                logger.warning(f'Unknown event: {event.name}')

    async def _process_emulation_state_changed(self, data):
        state = data['value']
        if state == 'machine-started':
            await self._process_machine_started()
        elif state == 'machine-paused':
            await self._process_machine_paused()
        elif state == 'emulation-cleared':
            await self._process_machine_cleared()
        else:
            logger.warning(f'Unknown emulation state: {state}')

    async def _process_machine_started(self):
        if not self.started:
            logger.info("Machine started.")
            self.started = True
            if self.emit_started_event:
                await self.emit_started_event()
        else:
            logger.debug("Machine resumed from pause.")
            if self.emit_resumed_event:
                await self.emit_resumed_event()

    async def _process_machine_paused(self):
        logger.info("Machine paused.")
        self.delayed_task = asyncio.create_task(self._delayed_pause_processing(self.pending_pause))
        self.pending_pause = False

    async def _delayed_pause_processing(self, pending: bool):
        await asyncio.sleep(0.5)
        if not pending and self.last_symbol in self.auto_restart_symbols:
                await self.resume()

        if self.emit_paused_event:
            await self.emit_paused_event(pending, self.last_symbol, self.last_unhandled_symbol == self.last_symbol)

    async def _process_machine_cleared(self):
        logger.info("Machine cleared.")
        self._resetting = False
        # Cancel any pending delayed pause task — stale after Clear
        if self.delayed_task:
            self.delayed_task.cancel()
            self.delayed_task = None
        self.started = False
        self.pending_pause = False
        self.last_symbol = None
        self.last_unknown_symbol = None
        self.auto_restart_symbols = []
        self.hook_map = {}
        if self.emit_reset_event:
            await self.emit_reset_event()

    async def _process_function_call(self, data):
        name = data['name']
        logger.info(f"🔵 Function called: {name}, entry={data.get('entry', 'unknown')}")
        self.last_symbol = name
        if self.emit_trace_event:
            logger.info(f"🟢 Emitting trace event for: {name}")
            await self.emit_trace_event(name, data['entry'])
        else:
            logger.warning("⚠️ emit_trace_event is not set!")

    async def _process_unhandled_access(self, data):
        name = data['name']
        pc = data['pc']
        is_write = data['write']
        address = data['address']
        width_in_bytes = data['width']
        value = data['value']

        self.last_unhandled_symbol = name

        logger.debug(f"Unhandled access: {name} at PC: {hex(pc)}, Address: {hex(address)}, Width: {width_in_bytes} bytes, Value: {hex(value)}, Write: {is_write}")
        if self.emit_unhandled_access_event:
            await self.emit_unhandled_access_event(name, pc, address, width_in_bytes, is_write, value)

    async def stop(self):
        logger.info("Stopping Renode and disconnecting from endpoints.")
        if self.proc:
            self.proc.terminate()
        
        if self.console:
            await self.console.disconnect()
            self.console = None

        if self.events:
            await self.events.disconnect()
            self.events = None

        if self.logging:
            await self.logging.disconnect()
            self.logging = None

    async def load(self, base_image: str, firmware_path: str):
        logger.info(f"Loading firmware into Renode: base_image='{base_image}', firmware_path='{firmware_path}'")
        await self.call('mach', 'create')

        load_result = await self.call('machine', 'LoadPlatformDescription', base_image)
        logger.info(f"📋 LoadPlatformDescription returned: {load_result}")

        # Debug: List all peripherals to find the CPU
        peripherals = await self.call('peripherals')
        logger.info(f"📋 Peripherals after load:\n{peripherals}")

        # Try getting registered peripherals from sysbus
        try:
            sysbus_peripherals = await self.call('sysbus', 'GetRegisteredPeripherals')
            logger.info(f"📋 Sysbus peripherals: {sysbus_peripherals}")
        except Exception as e:
            logger.info(f"⚠️ Could not get sysbus peripherals: {e}")

        await self.call('sysbus', 'LoadELF', firmware_path)
        await self.call('sysbus.cpu', 'WfiAsNop', 'True')
        logger.info("Enabling function name logging...")
        result = await self.call('sysbus.cpu', 'LogFunctionNames', 'True', 'True')
        logger.info(f"✓ LogFunctionNames result: {result}")

    async def setup_function_tracking_hooks(self, firmware_path: str):
        """
        Set up hooks at every function entry point to track function calls.
        This is a fallback when LogFunctionNames is not available.
        """
        logger.info("Setting up hook-based function tracking...")

        try:
            # Import here to avoid circular dependency
            from emulation_engine.callgraph.arm import extract_symbols

            # Get all function symbols from the ELF file
            symbols = extract_symbols(firmware_path)
            logger.info(f"Found {len(symbols)} symbols to track")

            # Define a hook that emits trace events
            # The hook code is Python that will execute when the function is called
            hook_code = """
import monitor
def trace_func(symbol_name):
    # This will be called when the hook is triggered
    pass
"""
            await self.define_hook('trace_hook', hook_code)

            # Map the hook to every function symbol
            hook_map = {}
            for symbol in symbols:
                hook_map[symbol] = 'trace_hook'

            await self.map_hooks(hook_map)
            logger.info(f"✓ Hook-based tracking set up for {len(symbols)} functions")
            return True

        except Exception as e:
            logger.error(f"Failed to set up hook-based tracking: {e}")
            return False

    async def run(self, start_from: str | None, end_at: list[str] | None, pause_on_unhandled: bool, auto_restart_symbols: list[str] = []):
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        
        self.auto_restart_symbols = auto_restart_symbols
        
        if start_from:
            logger.info(f"Setting program counter to: {start_from}")
            await self.console.set_program_counter(start_from)

        if end_at:
            logger.info(f"Adding pause at symbols: {end_at}")
            await self.console.add_pause(end_at)

        if pause_on_unhandled:
            logger.info("Pausing on unhandled access.")
            await self.call('sysbus', 'UnhandledAccessBehaviour', 'Pause')

        logger.info("Applying hooks and starting emulation.")
        await self.apply_hooks()
        await self.call('start')

    async def pause(self):
        logger.info("Pausing Renode.")
        self.pending_pause = True
        await self.call('pause')

    async def resume(self):
        logger.info("Resuming Renode.")
        self.pending_pause = False
        await self.call('start')

    async def reset(self):
        logger.info("Resetting Renode.")
        self._resetting = True
        self.started = False
        self.pending_pause = False
        self.last_symbol = None
        self.last_unknown_symbol = None
        self.auto_restart_symbols = []
        self.hook_map = {}
        # Cancel any pending delayed pause task before Clear
        if self.delayed_task:
            self.delayed_task.cancel()
            self.delayed_task = None
        await self.call('Clear')

    async def define_hook(self, hook_name: str, hook: str):
        logger.info(f"Defining hook: {hook_name}")
        self.hooks[hook_name] = hook

    async def map_hook(self, symbol: str, hook_name: str):
        logger.info(f"Mapping hook '{hook_name}' to symbol '{symbol}'")
        if hook_name not in self.hooks:
            raise Exception(f'Hook {hook_name} is not defined')
        self.hook_map[symbol] = hook_name

    async def map_hooks(self, hooks: dict[str, str]):
        for symbol, hook_name in hooks.items():
            await self.map_hook(symbol, hook_name)

    async def apply_hooks(self):
        for hook_name, hook in self.hooks.items():
            await self._set_variable(hook_name, hook)

        for symbol, hook_name in self.hook_map.items():
            await self._add_hook(symbol, hook_name)

    async def write_memory(self, address: int, data: bytes):
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        logger.info(f'Writing {len(data)} bytes to memory address: {hex(address)}')
        await self.console.write_memory(address, data)

    async def read_memory(self, address: int, size_in_bytes: int):
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        logger.info(f'Reading {size_in_bytes} bytes from memory address: {hex(address)}')
        return await self.console.read_memory(address, size_in_bytes)
    
    async def write_registers(self, registers: dict[int, int]):
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        logger.info(f'Writing registers: {registers}')
        return await self.console.write_registers(registers)
    
    async def read_registers(self):
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        logger.info('Reading registers')
        return await self.console.read_registers()
        
    async def set_constant(self, address: int, name: str, width_in_bytes: int, value: int):
        if not self.console:
            raise Exception("Renode is not running. Please start it first.")
        logger.info(f'Setting constant: {name} at address: {hex(address)} with value: {hex(value)} and width: {width_in_bytes} bytes')
        await self.console.set_constant(address, name, width_in_bytes, value)

    async def _set_variable(self, name: str, value: str):
        await self.call('set', name, f'\n"""\n{value}\n"""')

    async def _add_hook(self, symbol: str, hook_name: str):
        await self.call('sysbus', 'AddHookAtSymbol', f'"{symbol}"', f'${hook_name}')
