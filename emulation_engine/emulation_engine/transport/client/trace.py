
from typing import Coroutine, Callable, Any, Literal
import socketio

import logging
logger = logging.getLogger(__name__)

class TraceNamespace(socketio.AsyncClientNamespace):
    def __init__(self, namespace='/trace'):
        super().__init__(namespace)

        self.handle_connect: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_trace: Callable[[str, bool], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"TraceNamespace initialized on namespace '{namespace}'")

    async def on_connect(self):
        if self.handle_connect:
            await self.handle_connect()
    
    async def on_disconnect(self, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(reason)

    async def on_trace(self, symbol : str, entry: bool):
        if self.handle_trace:
            logger.info(f"Received trace event: symbol={symbol}, entry={entry}")
            await self.handle_trace(symbol, entry)
        else:
            logger.warning("No handler defined for trace event.")