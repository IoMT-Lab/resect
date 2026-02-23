import asyncio
import os
import sys

from ..console_endpoint import ConsoleEndpoint

async def main():
    hostname = os.getenv('RENODE_HOST', 'localhost')
    port = int(os.getenv('RENODE_PORT', 5000))

    # reader = asyncio.StreamReader()
    # pipe = sys.stdin
    # loop = asyncio.get_event_loop()
    # await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), pipe)

    print(f'Connecting to Renode @{hostname}:{port}')
    endpoint = ConsoleEndpoint(hostname, port)
    await endpoint.connect()
    print(await endpoint.read_memory(0x20000000, 16))
    print(await endpoint.write_memory(0x20000000, b'\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10'))
    val, reg = await endpoint.read_registers()
    print(reg)

    reg[0] = 0x12345678

    await endpoint.write_registers(reg) # type: ignore

    await endpoint.set_constant(0x20000000, 'MY_CONSTANT', 32, 0xDEADBEEF)

    # print("Connected.\nEnter commands (Ctrl+C to exit):")
    # print(">> ", end='')
    # try:
    #     async for line in reader:
    #         status, response = await endpoint.call(line.decode().strip())
    #         if status:
    #             print(response)
    #         else:
    #             print(f'!ERROR! {response}')
    #         print("\n>> ", end='')
    # finally:
    #     await endpoint.disconnect()

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print('Exiting program')

