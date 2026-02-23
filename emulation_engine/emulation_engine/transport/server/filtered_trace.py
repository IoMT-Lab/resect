from typing import Coroutine, Callable, Any
import socketio

import logging
logger = logging.getLogger(__name__)

class FilteredTraceNamespace(socketio.AsyncNamespace):
    """
    Filtered trace namespace that only emits the first call of each function.
    This is optimized for graph visualization where you only need to know
    when a function was first executed, not every single call.
    """
    def __init__(self, namespace='/trace_filtered'):
        super().__init__(namespace)

        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_reset: Callable[[], Coroutine[Any, Any, None]] | None = None

        # Tracking state for first-call filtering
        self._seen_functions: set[str] = set()

        logger.info(f"FilteredTraceNamespace initialized on namespace '{namespace}'")

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)

    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def emit_trace(self, symbol: str, entry: bool):
        """
        Emit trace event only for first entry of each function.
        Exit events are ignored.
        """
        if entry:
            # Only emit first entry of each function
            if symbol not in self._seen_functions:
                self._seen_functions.add(symbol)
                logger.debug(f"Emitting FIRST trace event: symbol={symbol}")
                await self.emit('trace', (symbol, entry))
            else:
                logger.debug(f"Skipping duplicate trace event: symbol={symbol}")
        # Ignore all exit events

    def clear_tracking(self):
        """Clear the set of seen functions. Called on reset."""
        logger.info("Clearing filtered trace tracking state")
        self._seen_functions.clear()
