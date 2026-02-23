import socketio

from .callgraph import CallgraphNamespace
from .console import ConsoleNamespace
from .lifecycle import LifecycleNamespace
from .log import LogNamespace
from .trace import TraceNamespace
from .memory import MemoryNamespace

class Client:
    def __init__(self):
        self.sio = socketio.AsyncClient()
        self.callgraph = CallgraphNamespace()
        self.console = ConsoleNamespace()
        self.lifecycle = LifecycleNamespace()
        self.log = LogNamespace()
        self.trace = TraceNamespace()
        self.memory = MemoryNamespace()
        
        self.sio.register_namespace(self.callgraph)
        self.sio.register_namespace(self.console)
        self.sio.register_namespace(self.lifecycle)
        self.sio.register_namespace(self.log)
        self.sio.register_namespace(self.trace)
        self.sio.register_namespace(self.memory)

    async def connect(self, uri):
        return await self.sio.connect(uri)
    
    async def wait(self):
        return await self.sio.wait()
    
    async def disconnect(self):
        return await self.sio.disconnect()
    
    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.disconnect()

