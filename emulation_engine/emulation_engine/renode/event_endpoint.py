from typing import Any, AsyncIterator
from .websocket_endpoint import WebSocketEndpoint
from .websocket_api import APIFail, APIRequest, APIResponse, APIEvent, APISuccess

import logging
logger = logging.getLogger(__name__)

class EventEndpoint:
    def __init__(self, host: str, port: int, events: list[str]):
        self.endpoint = WebSocketEndpoint(host, port, '/proxy')
        self.events = events

    async def connect(self):
        async with self.endpoint.lock:
            logger.info(f"Connecting to EventEndpoint at {self.endpoint.uri}")
            await self.endpoint.connect()
            logger.info("EventEndpoint connection established.")
            for event in self.events:
                await self._subscribe(event)

    async def disconnect(self):
        async with self.endpoint.lock:
            logger.info(f"Disconnecting from EventEndpoint at {self.endpoint.uri}")
            await self.endpoint.disconnect()
            logger.info("EventEndpoint connection closed.")

    async def _subscribe(self, event: str):
        logger.debug(f'Subscribing to event: {event}')
        request = APIRequest('subscribe', {'eventName': event})
        response = await self.endpoint.call(request)

        if response is APISuccess:
            logger.debug(f'Successfully subscribed to event: {event}')
        elif response is APIFail:
            logger.warning(f"Error in subscription response: {response.error}")

    async def next(self) -> APIEvent:
        async with self.endpoint.lock:
            event = None
            while not event:
                msg = await self.endpoint.read()
                event = APIEvent.from_json(msg)

                if event:
                    logger.debug(f"Received event: {event.name}")
                else:
                    logger.warning(f"Received message is not a valid event: {msg}")

            return event
    
    async def __aiter__(self) -> AsyncIterator[APIEvent]:
        while True:
            yield await self.next()
  


