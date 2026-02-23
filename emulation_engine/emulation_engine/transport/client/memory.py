
from typing import Coroutine, Callable, Any, Literal
import socketio
import base64

import logging

from emulation_engine.memory import Snapshot
logger = logging.getLogger(__name__)

class MemoryNamespace(socketio.AsyncClientNamespace):
    def __init__(self, namespace='/memory'):
        super().__init__(namespace)

        self.handle_connect: Callable[[], Coroutine[Any, Any, Any]] | None = None
        self.handle_disconnect: Callable[[str], Coroutine[Any, Any, Any]] | None = None

        logger.info(f"MemoryNamespace initialized on namespace '{namespace}'")

    async def on_connect(self):
        if self.handle_connect:
            await self.handle_connect()
    
    async def on_disconnect(self, reason):
        if self.handle_disconnect:
            await self.handle_disconnect(reason)

    async def call_write(self, address: int, data: bytes):
        logger.debug(f"Calling memory write: address={hex(address)}, data={len(data)} bytes")
        return await self.call('write', (address, data))
    
    async def call_read(self, address: int, size_in_bytes: int):
        logger.debug(f"Calling memory read: address={hex(address)}, size={size_in_bytes} bytes")
        return await self.call('read', (address, size_in_bytes))
    
    async def call_write_registers(self, registers: dict[int, int]):
        logger.debug(f"Calling write registers: {registers}")
        return await self.call('write_registers', registers)
    
    async def call_read_registers(self):
        logger.debug(f"Calling read registers")
        return await self.call('read_registers')
    
    async def call_set_constant(self, address: int, name: str, width_in_bytes: int, value: int):
        logger.debug(f"Calling set constant: address={hex(address)}, name={name}, width={width_in_bytes} bytes, value={hex(value)}")
        return await self.call('set_constant', (address, name, width_in_bytes, value))
    
    async def call_restore(self, snapshot: Snapshot):
        logger.debug(f'Calling restore')
        return await self.call('restore', snapshot.to_dict())
    
    async def call_save(self, memory_regions: dict[int, int]):
        logger.debug(f'Calling save')
        snapshot = await self.call('save', memory_regions)
        return Snapshot.from_dict(snapshot)