from .websocket_endpoint import WebSocketEndpoint
from .websocket_api import APIRequest, APIResponse, APISuccess, APIFail

import base64

import logging
logger = logging.getLogger(__name__)

class ConsoleEndpoint:
    def __init__(self, host: str, port: int):
        self.endpoint = WebSocketEndpoint(host, port, '/proxy')

    async def connect(self):
        logger.info(f"Connecting to ConsoleEndpoint at {self.endpoint.uri}")
        async with self.endpoint.lock:
            await self.endpoint.connect()
        logger.info("ConsoleEndpoint connection established.")

    async def disconnect(self):
        logger.info(f"Disconnecting from ConsoleEndpoint at {self.endpoint.uri}")
        async with self.endpoint.lock:
            await self.endpoint.disconnect()
        logger.info("ConsoleEndpoint connection closed.")

    async def call(self, command: str, *args) -> str:
        async with self.endpoint.lock:
            command_str = f'{command} {' '.join(args)}'
            logger.debug(f"Sending command: {command_str}")
            request = APIRequest('exec-monitor', {'commands': [command_str]})
            response = await self.endpoint.call(request)

            data = response.get_or_throw()
            return data[0]
        
    async def set_program_counter(self, symbol: str):
        async with self.endpoint.lock:
            logger.debug(f'Setting program counter to symbol: {symbol}')
            request = APIRequest('set-program-counter', {'symbol': symbol})
            response = await self.endpoint.call(request)
            response.get_or_throw()

    async def add_pause(self, symbols: list[str]):
        async with self.endpoint.lock:
            logger.debug(f'Adding pause at symbols: {symbols}')
            request = APIRequest('add-pause', {'symbols': symbols})
            response = await self.endpoint.call(request)
            response.get_or_throw()
            
    async def write_memory(self, address: int, data: bytes):
        async with self.endpoint.lock:
            logger.debug(f'Writing {len(data)} bytes of memory to address: {hex(address)}')
            request = APIRequest('write-memory', {'address': address, 'base64EncodedData': base64.b64encode(data).decode('utf-8')})
            response = await self.endpoint.call(request)
            response.get_or_throw()
            
    async def read_memory(self, address:int, size_in_bytes: int) -> bytes:
        async with self.endpoint.lock:
            logger.debug(f'Reading {size_in_bytes} bytes of memory from address: {hex(address)}')
            request = APIRequest('read-memory', {'address': address, 'width': size_in_bytes})
            response = await self.endpoint.call(request)
            data = response.get_or_throw()
            return base64.b64decode(data)
            
    async def write_registers(self, registers: dict[int, int]):
        async with self.endpoint.lock:
            logger.debug(f'Writing registers: {registers}')
            request = APIRequest('write-registers', {'registers': registers})
            response = await self.endpoint.call(request)
            response.get_or_throw()
            
    async def read_registers(self) -> dict[int, int]:
        async with self.endpoint.lock:
            logger.debug('Reading registers')
            request = APIRequest('read-registers', {})
            response = await self.endpoint.call(request)
            return response.get_or_throw()
            
    async def set_constant(self, address: int, name: str, width_in_bytes: int, value: int):
        async with self.endpoint.lock:
            logger.debug(f'Setting constant {name} at address {hex(address)} with width {width_in_bytes} to value {value}')
            request = APIRequest('set-constant', {'address': address, 'name': name, 'width': width_in_bytes, 'value': value})
            response = await self.endpoint.call(request)
            response.get_or_throw()