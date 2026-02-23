import asyncio
import os
import sys

from ..event_endpoint import EventEndpoint

async def main():
    hostname = os.getenv('RENODE_HOST', 'localhost')
    port = int(os.getenv('RENODE_PORT', 5000))

    events = sys.argv[1:]
    if len(events) == 0:
        print('Subscribe to at least one event')
        return
    
    print('Events to listen for:')
    for event in events:
        print(f'\t{event}')

    print(f'Connecting to Renode @{hostname}:{port}')
    endpoint = EventEndpoint(hostname, port, events)
    await endpoint.connect()
    
    async for event in endpoint:
        print(f'{event.name} :: {event.data}')

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print('Exiting program')