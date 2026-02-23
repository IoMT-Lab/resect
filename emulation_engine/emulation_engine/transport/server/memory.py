from typing import Coroutine, Callable, Any
import socketio

import logging

from emulation_engine.memory import Snapshot
logger = logging.getLogger(__name__)

class MemoryNamespace(socketio.AsyncNamespace):
    def __init__(self, namespace='/memory'):
        super().__init__(namespace)

        self.handle_connect: Callable[[str], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str, str], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_write: Callable[[int, bytes], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_read: Callable[[int, int], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_write_registers: Callable[[dict[int, int]], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_read_registers: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_set_constant: Callable[[int, str, int, int], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_restore: Callable[[Snapshot], Coroutine[Any, Any, Any]] | None = None
        self.handle_on_save: Callable[[dict[int, int]], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"MemoryNamespace initialized on namespace '{namespace}'")

    async def on_connect(self, sid, environ):
        if self.handle_connect:
            await self.handle_connect(sid)
    
    async def on_disconnect(self, sid, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(sid, reason)

    async def on_write(self, sid, address: int, data: bytes):
        if self.handle_on_write:
            logger.info(f"Received memory write request: address={hex(address)}, data={len(data)} bytes")
            return await self.handle_on_write(address, data)
        else:
            logger.warning("No handler defined for memory write.")
            return False, 'Not implemented'

    async def on_read(self, sid, address: int, size_in_bytes: int):
        if self.handle_on_read:
            logger.info(f"Received memory read request: address={hex(address)}, size={size_in_bytes} bytes")
            return await self.handle_on_read(address, size_in_bytes)
        else:
            logger.warning("No handler defined for memory read.")
            return False, 'Not implemented'

    async def on_write_registers(self, sid, registers: dict[int, int]):
        if self.handle_on_write_registers:
            logger.info(f"Received write registers request: {registers}")
            return await self.handle_on_write_registers(registers)
        else:
            logger.warning("No handler defined for write registers.")
            return False, 'Not implemented'

    async def on_read_registers(self, sid):
        if self.handle_on_read_registers:
            logger.info(f"Received read registers request")
            return await self.handle_on_read_registers()
        else:
            logger.warning("No handler defined for read registers.")
            return False, 'Not implemented'

    async def on_set_constant(self, sid, address: int, name: str, width_in_bytes: int, value: int):
        if self.handle_on_set_constant:
            logger.info(f"Received set constant request: address={hex(address)}, name={name}, width={width_in_bytes} bytes, value={hex(value)}")
            return await self.handle_on_set_constant(address, name, width_in_bytes, value)
        else:
            logger.warning("No handler defined for set constant.")
            return False, 'Not implemented'
        
    async def on_restore(self, sid, snapshot):
        if self.handle_on_restore:
            logger.info(f"Received restore request")
            snapshot = Snapshot.from_dict(snapshot)
            return await self.handle_on_restore(snapshot)
        else:
            logger.warning("No handler defined for restore")
            return False, 'Not implemented'
        
    async def on_save(self, sid, memory_regions: dict[int, int]):
        if self.handle_on_save:
            logger.info(f'Received request to save regions: {memory_regions}')
            snapshot = await self.handle_on_save(memory_regions)
            return snapshot.to_dict()
        else:
            logger.warning("No handler defined for save")
            return False, 'Not implemented'