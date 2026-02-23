from typing import Coroutine, Callable, Any
import socketio

class LogNamespace(socketio.AsyncNamespace):
    def __init__(self, namespace='/log'):
        super().__init__(namespace)

        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_log_level: Callable[[str], Coroutine[Any, Any, Any]] | None = None

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)

    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def on_log_level(self, sid, level: str):
        if self.handle_log_level:
            return await self.handle_log_level(level)
        else:
            return False, 'Not implemented'

    async def emit_log(self, log: str):
        await self.emit('log', log)