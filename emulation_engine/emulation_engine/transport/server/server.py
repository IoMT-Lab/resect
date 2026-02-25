import socketio
import uvicorn

from .callgraph import CallgraphNamespace
from .console import ConsoleNamespace
from .lifecycle import LifecycleNamespace
from .log import LogNamespace
from .trace import TraceNamespace
from .filtered_trace import FilteredTraceNamespace
from .memory import MemoryNamespace

from ...callgraph.arm import ARMCallgraph

from ...renode.renode import Renode

import logging
logger = logging.getLogger(__name__)

class Server(socketio.AsyncNamespace):
    def __init__(self, renode_path, renode_port, logging_path):
        super().__init__()

        logger.info("Initializing Server...")

        self.sio = socketio.AsyncServer(async_mode='asgi')
        self.arm_callgraph = ARMCallgraph()

        self.callgraph = CallgraphNamespace()
        self.callgraph.handle_get_symbols = self.arm_callgraph.extract_symbols
        self.callgraph.handle_get_callgraph = self.arm_callgraph.generate_callgraph

        self.console = ConsoleNamespace()
        self.lifecycle = LifecycleNamespace()
        self.log = LogNamespace()
        self.trace = TraceNamespace()
        self.filtered_trace = FilteredTraceNamespace()
        self.memory = MemoryNamespace()

        self.renode = Renode(renode_path, logging_path)
        self.renode_port = renode_port
        self.callgraph.handle_get_asm_symbols = self.renode.get_symbols

        self.renode.emit_started_event = self.lifecycle.emit_started_event
        self.renode.emit_paused_event = self.lifecycle.emit_paused_event
        self.renode.emit_resumed_event = self.lifecycle.emit_resumed_event
        self.renode.emit_reset_event = self.lifecycle.emit_reset_event
        self.renode.emit_unhandled_access_event = self.lifecycle.emit_unhandled_access

        # Wire both trace namespaces to receive trace events
        self.renode.emit_trace_event = self._emit_to_both_trace_namespaces
        
        self.console.handle_command = self.renode.call
        self.lifecycle.handle_load = self.renode.load
        self.lifecycle.handle_start = self.renode.run
        self.lifecycle.handle_pause = self.renode.pause
        self.lifecycle.handle_resume = self.renode.resume
        self.lifecycle.handle_reset = self._handle_reset
        self.lifecycle.handle_define_hook = self.renode.define_hook
        self.lifecycle.handle_map_hooks = self.renode.map_hooks
        self.memory.handle_on_write = self.renode.write_memory
        self.memory.handle_on_read = self.renode.read_memory
        self.memory.handle_on_write_registers = self.renode.write_registers
        self.memory.handle_on_read_registers = self.renode.read_registers
        self.memory.handle_on_set_constant = self.renode.set_constant
        self.memory.handle_on_restore = self.renode.restore
        self.memory.handle_on_save = self.renode.save

        self.sio.register_namespace(self)
        self.sio.register_namespace(self.callgraph)
        self.sio.register_namespace(self.console)
        self.sio.register_namespace(self.lifecycle)
        self.sio.register_namespace(self.log)
        self.sio.register_namespace(self.trace)
        self.sio.register_namespace(self.filtered_trace)
        self.sio.register_namespace(self.memory)

    async def _emit_to_both_trace_namespaces(self, symbol: str, entry: bool):
        """Emit trace events to both regular and filtered trace namespaces."""
        await self.trace.emit_trace(symbol, entry)
        await self.filtered_trace.emit_trace(symbol, entry)

    async def _handle_reset(self):
        """Handle reset: clear filtered trace tracking and reset renode."""
        self.filtered_trace.clear_tracking()
        await self.renode.reset()

    async def on_startup(self):
        logger.info("Server starting up...")
        await self.renode.start(self.renode_port, output=False)
        self.background_task = self.sio.start_background_task(self.background)

    async def background(self):
        await self.renode.process_events()

    async def on_shutdown(self):
        logger.info("Server shutting down...")
        await self.renode.stop()

    def listen(self, port, log_level='info'):
        logger.info(f"Server listening on port {port}...")
        self.task = self.sio.start_background_task(self.background)
        app = socketio.ASGIApp(self.sio, on_startup = self.on_startup, on_shutdown = self.on_shutdown)
        uvicorn.run(app, port=port, log_level=log_level)