from typing import Coroutine, Callable, Any
import socketio

import logging
logger = logging.getLogger(__name__)

class ConsoleNamespace(socketio.AsyncNamespace):
    def __init__(self, namespace='/console'):
        super().__init__(namespace)

        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_command: Callable[[str], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"ConsoleNamespace initialized on namespace '{namespace}'")

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)

    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def on_command(self, sid, command: str):
        if self.handle_command:
            logger.info(f"Received command request: {command}")
            return await self.handle_command(command)
        else:
            logger.warning("No handler defined for command request.")
            return False, 'Not implemented'