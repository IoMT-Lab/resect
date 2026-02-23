
from typing import Coroutine, Callable, Any, Literal
import socketio

import logging
logger = logging.getLogger(__name__)

class LifecycleNamespace(socketio.AsyncClientNamespace):
    def __init__(self, namespace='/lifecycle'):
        super().__init__(namespace)

        self.handle_connect: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str], Coroutine[Any, Any, Any]] | None = None

        self.handle_started: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_paused: Callable[[bool, str | None, bool | None], Coroutine[Any, Any, Any]] | None = None
        self.handle_resumed: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_reset: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_unhandled_access: Callable[[str, int, int, int, bool, int], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"LifecycleNamespace initialized on namespace '{namespace}'")

    async def on_connect(self):
        if self.handle_connect:
            await self.handle_connect()
    
    async def on_disconnect(self, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(reason)

    async def on_started(self):
        if self.handle_started:
            logger.info("Received started event")
            await self.handle_started()
        else:
            logger.warning("No handler defined for started event.")

    async def on_paused(self, user: bool, symbol: str | None, unhandled_access: bool | None):
        if self.handle_paused:
            logger.info(f"Received paused event: user={user}, symbol={symbol}, unhandled_access={unhandled_access}")
            await self.handle_paused(user, symbol, unhandled_access)
        else:
            logger.warning("No handler defined for paused event.")

    async def on_resumed(self):
        if self.handle_resumed:
            logger.info("Received resumed event")
            await self.handle_resumed()
        else:
            logger.warning("No handler defined for resumed event.")

    async def on_reset(self):
        if self.handle_reset:
            logger.info("Received reset event")
            await self.handle_reset()
        else:
            logger.warning("No handler defined for reset event.")

    async def on_unhandled_access(self, symbol: str, program_counter: int, address: int, width_in_bytes: int, is_write: bool, value: int):
        if self.handle_unhandled_access:
            logger.info(f"Received unhandled access event for symbol: {symbol}")
            await self.handle_unhandled_access(symbol, program_counter, address, width_in_bytes, is_write, value)
        else:
            logger.warning(f"No handler defined for unhandled access event")

    async def call_load(self, base_image: str, firmware_path: str):
        logger.debug(f"Calling load with base_image: {base_image}, firmware_path: {firmware_path}")
        return await self.call('load', (base_image, firmware_path))
    
    async def call_define_hook(self, hook_name: str, hook: str):
        logger.debug(f"Calling define_hook with hook_name: {hook_name}")
        return await self.call('define_hook', (hook_name, hook))
    
    async def call_map_hooks(self, hooks: dict[str, str]):
        logger.debug(f"Calling map_hooks with hooks: {list(hooks.keys())}")
        return await self.call('map_hooks', hooks)
    
    async def call_start(self, start_from : str | None = None, end_at: list[str] | None = None, pause_on_unhandled: bool = True, auto_restart_symbols: list[str] = []):
        logger.debug(f"Calling start with start_from: {start_from}, end_at: {end_at}, pause_on_unhandled: {pause_on_unhandled}, auto_restart_symbols: {auto_restart_symbols}")
        return await self.call('start', (start_from, end_at, pause_on_unhandled, auto_restart_symbols))
    
    async def call_pause(self):
        logger.debug("Calling pause")
        return await self.call('pause')
    
    async def call_resume(self):
        logger.debug("Calling resume")
        return await self.call('resume')
    
    async def call_reset(self):
        logger.debug("Calling reset")
        return await self.call('reset')
