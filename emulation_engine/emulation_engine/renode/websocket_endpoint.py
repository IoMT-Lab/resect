from websockets.asyncio import client
import asyncio
from .websocket_api import APIRequest, APIResponse, parse_response

import logging
logger = logging.getLogger(__name__)

class WebSocketEndpoint:
    def __init__(self, host: str, port: int, path: str):
        self.uri = f'ws://{host}:{port}{path}'
        self.websocket : client.ClientConnection | None = None
        self.read_task = None
        self.lock = asyncio.Lock()

    async def connect(self) -> None:
        logger.info(f"Connecting to WebSocket at {self.uri}")
        if self.websocket:
            logger.warning("WebSocket is already connected.")
            pass
        else:
            self.websocket = await client.connect(self.uri)
            logger.info("WebSocket connection established.")

    def is_connected(self):
        return self.websocket is not None

    async def disconnect(self) -> None:
        logger.info(f"Disconnecting from WebSocket at {self.uri}")
        if not self.websocket:
            logger.warning("WebSocket is not connected.")
        else:
            await self.websocket.close()
            logger.info("WebSocket connection closed.")
            self.websocket = None

    async def __aenter(self):
        await self.connect()
        return self
    
    async def __aexit(self, exc_type, exc, tb):
        await self.disconnect()

    async def read(self) -> str | None:
        if self.websocket:
            msg = await self.websocket.recv(decode=True)
            logger.debug(f"Received message: {msg}")
            return msg
        else:
            logger.warning("WebSocket is not connected. Cannot read message.")
            return None
        
    async def read_line(self) -> str | None:
        if self.websocket:
            buffer = []
            while True:
                msg = await self.websocket.recv(decode=True)
                buffer.append(msg)
                if msg.endswith('\n'):
                    break
            return ''.join(buffer)
        
    async def _read_loop(self, callback):
        if self.websocket is None:
            return
        
        try:
            async for message in self.websocket:
                if message is not None:
                    logger.debug(f"Received message: {message}")
                    await callback(message)
        except asyncio.CancelledError:
            pass

    def start_read_loop(self, callback):
        if self.read_task is None:
            if self.websocket:
                self.read_task = asyncio.create_task(self._read_loop(callback))
                logger.debug("Started WebSocket read loop.")
            else:
                logger.warning("WebSocket is not connected. Cannot start read loop.")
        else:
            logger.warning("Read loop is already running.")

    async def wait(self):
        if self.read_task:
            await self.read_task
    
    async def stop_read_loop(self):
        if self.read_task:
            try:
                self.read_task.cancel()
                await self.read_task
            except asyncio.CancelledError:
                pass
            finally:
                self.read_task = None

    async def send(self, msg: str) -> None:
        if self.websocket:
            logger.debug(f"Sending message: {msg}")
            await self.websocket.send(msg)
            logger.debug("Message sent.")
        else:
            logger.warning("WebSocket is not connected. Cannot send message.")

    async def send_line(self, msg: str) -> None:
        await self.send(f'{msg}\n')

    async def call(self, request: APIRequest) -> APIResponse:
        await self.send(request.to_json())
        return await self._wait_for_response()

    async def _wait_for_response(self) -> APIResponse:
        response = None
        while not response:
            msg = await self.read()
            response = parse_response(msg)
        return response