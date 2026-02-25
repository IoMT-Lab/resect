from typing import Coroutine, Callable, Any, Literal
import socketio

import logging
logger = logging.getLogger(__name__)


class CallgraphNamespace(socketio.AsyncNamespace):
    def __init__(self, namespace='/callgraph'):
        super().__init__(namespace)
        
        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_get_symbols: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_get_asm_symbols: Callable[[bool], Coroutine[Any, Any, Any]] | None = None
        self.handle_get_callgraph: Callable[[str], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"CallgraphNamespace initialized on namespace '{namespace}'")

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)

    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def on_get_symbols(self, sid, firmware_path: str):
        if self.handle_get_symbols:
            logger.info(f"Received get_symbols request for firmware: {firmware_path}")
            return await self.handle_get_symbols(firmware_path)
        else:
            logger.warning("No handler defined for get_symbols request.")
            return False, 'Not implemented'

    async def on_get_callgraph(self, sid, firmware_path: str):
        if self.handle_get_callgraph:
            logger.info(f"Received get_callgraph request for firmware: {firmware_path}")
            return await self.handle_get_callgraph(firmware_path)
        else:
            logger.warning("No handler defined for get_callgraph request.")
            return False, 'Not implemented'
        
    async def on_get_asm_symbols(self, sid):
        if self.handle_get_asm_symbols:
            logger.info(f"Received get_asm_symbols request")
            return await self.handle_get_asm_symbols(True)
        else:
            logger.warning("No handler defined for get_asm_symbols request.")
            return False, 'Not implemented'