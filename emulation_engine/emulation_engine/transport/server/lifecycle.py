from typing import Coroutine, Callable, Any
import socketio

import logging
logger = logging.getLogger(__name__)

class LifecycleNamespace(socketio.AsyncNamespace):
    def __init__(self, namespace='/lifecycle'):
        super().__init__(namespace)

        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_load: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_define_hook: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_map_hooks: Callable[[dict[str, str]], Coroutine[Any, Any, Any]] | None = None
        self.handle_start: Callable[ [str | None, list[str] | None, bool, list[str]], Coroutine[Any, Any, Any]] | None = None
        self.handle_pause: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_resume: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_reset: Callable[[], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"LifecycleNamespace initialized on namespace '{namespace}'")

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)

    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def on_load(self, sid, base_image: str, firmware_path: str):
        if self.handle_load:
            # Wrap the paths in double-quotes, or Renode won't be happy
            base_image = f'"{base_image}"'
            firmware_path = f'"{firmware_path}"'
            logger.info(f"Received load request: base_image='{base_image}', firmware_path='{firmware_path}'")
            return await self.handle_load(base_image, firmware_path)
        else:
            logger.warning("No handler defined for load request.")
            return False, 'Not implemented'

    async def on_define_hook(self, sid, hook_name: str, hook: str):
        if self.handle_define_hook:
            logger.info(f"Received define_hook request: hook_name='{hook_name}'")
            return await self.handle_define_hook(hook_name, hook)
        else:
            logger.warning("No handler defined for define_hook request.")
            return False, 'Not implemented'

    async def on_map_hooks(self, sid, hooks: dict[str, str]):
        if self.handle_map_hooks:
            logger.info(f"Received map_hooks request with hooks: {list(hooks.keys())}")
            return await self.handle_map_hooks(hooks)
        else:
            logger.warning("No handler defined for map_hooks request.")
            return False, 'Not implemented'

    async def on_start(self, sid, start_from: str | None = None, end_at: list[str] | None = None, pause_on_unhandled: bool = True, auto_restart_symbols: list[str] = []):
        if self.handle_start:
            logger.info(f"Received start request: start_from='{start_from}', end_at='{end_at}', pause_on_unhandled='{pause_on_unhandled}', auto_restart_symbols={auto_restart_symbols}")
            return await self.handle_start(start_from, end_at, pause_on_unhandled, auto_restart_symbols)
        else:
            logger.warning("No handler defined for start request.")
            return False, 'Not implemented'

    async def on_pause(self, sid):
        if self.handle_pause:
            logger.info("Received pause request.")
            return await self.handle_pause()
        else:
            logger.warning("No handler defined for pause request.")
            return False, 'Not implemented'

    async def on_resume(self, sid):
        if self.handle_resume:
            logger.info("Received resume request.")
            return await self.handle_resume()
        else:
            logger.warning("No handler defined for resume request.")
            return False, 'Not implemented'

    async def on_reset(self, sid):
        if self.handle_reset:
            logger.info("Received reset request.")
            return await self.handle_reset()
        else:
            logger.warning("No handler defined for reset request.")
            return False, 'Not implemented'

    async def emit_started_event(self):
        logger.debug("Emitting started event.")
        await self.emit('started')

    async def emit_paused_event(self, user: bool, symbol: str | None, unhandled_access: bool | None):
        logger.debug(f"Emitting paused event: user={user}, symbol={symbol}, unhandled_access={unhandled_access}")
        await self.emit('paused', (user, symbol, unhandled_access))

    async def emit_resumed_event(self):
        logger.debug("Emitting resumed event.")
        await self.emit('resumed')

    async def emit_reset_event(self):
        logger.debug("Emitting reset event.")
        await self.emit('reset')

    async def emit_unhandled_access(self, symbol : str, program_counter: int, address: int, width_in_bytes: int, is_write: bool, value: int):
        logger.debug(f"Emitting unhandled_access event for symbol: {symbol}, program_counter: {hex(program_counter)}, address: {hex(address)}, width_in_bytes: {width_in_bytes}, is_write: {is_write}, value: {hex(value)}")
        await self.emit('unhandled_access', (symbol, program_counter, address, width_in_bytes, is_write, value))