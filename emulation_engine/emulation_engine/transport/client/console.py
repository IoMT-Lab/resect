from typing import Coroutine, Callable, Any, Literal
import socketio

import logging
logger = logging.getLogger(__name__)

class ConsoleNamespace(socketio.AsyncClientNamespace):
    def __init__(self, namespace='/console'):
        super().__init__(namespace)

        self.handle_connect: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"ConsoleNamespace initialized on namespace '{namespace}'")

    async def on_connect(self):
        if self.handle_connect:
            await self.handle_connect()
    
    async def on_disconnect(self, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(reason)

    async def call_command(self, command : str):
        logger.debug(f"Calling command with command: {command}")
        return await self.call('command', command)