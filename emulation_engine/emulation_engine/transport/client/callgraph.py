
from typing import Coroutine, Callable, Any, Literal
import socketio

import logging
logger = logging.getLogger(__name__)

class CallgraphNamespace(socketio.AsyncClientNamespace):
    def __init__(self, namespace='/callgraph'):
        super().__init__(namespace)

        self.handle_connect: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"CallgraphNamespace initialized on namespace '{namespace}'")

    async def on_connect(self):
        if self.handle_connect:
            await self.handle_connect()

    async def on_disconnect(self, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(reason)

    async def call_get_symbols(self, firmware_path: str):
        logger.debug(f"Calling get_symbols with firmware_path: {firmware_path}")
        return await self.call('get_symbols', firmware_path)
    
    async def call_get_callgraph(self, firmware_path: str):
        logger.debug(f"Calling get_callgraph with firmware_path: {firmware_path}")
        return await self.call("get_callgraph", firmware_path)