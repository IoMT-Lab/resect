import asyncio
import os
import sys

from ..logging_endpoint import LoggingEndpoint

async def aprint(msg: str):
    print(msg, end='')

async def main():
    hostname = os.getenv('RENODE_HOST', 'localhost')
    port = int(os.getenv('RENODE_PORT', 5000))

    if len(sys.argv) < 3:
        print("Must specify logging and shell files")
        return

    logging_filename = sys.argv[1]
    shell_filename = sys.argv[2]

    print(f'Connecting to Renode @{hostname}:{port}')
    endpoint = LoggingEndpoint(hostname, port, logging_filename, shell_filename)
    await endpoint.connect()
    try:
        print("Connected. (Ctrl+C to exit)")
        await endpoint.wait()
    finally:
        await endpoint.disconnect()
    
if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Exiting program.")