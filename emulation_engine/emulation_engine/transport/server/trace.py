from typing import Coroutine, Callable, Any
import socketio

import logging
logger = logging.getLogger(__name__)

class TraceNamespace(socketio.AsyncNamespace):
    def __init__(self, namespace='/trace'):
        super().__init__(namespace)

        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"TraceNamespace initialized on namespace '{namespace}'")

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)

    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def emit_trace(self, symbol: str, entry: bool):
        logger.debug(f"Emitting trace event: symbol={symbol}, entry={entry}")
        await self.emit('trace', (symbol, entry))
