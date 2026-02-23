from .websocket_endpoint import WebSocketEndpoint
from aiofile import async_open

async def aprint(msg):
    print(msg, end='')

class LoggingEndpoint:
    def __init__(self, host: str, port: int, log_filename='log.txt', shell_filename='shell.txt'):
        self.logging_endpoint = WebSocketEndpoint(host, port, '/telnet/29170')
        self.shell_endpoint = WebSocketEndpoint(host, port, '/telnet/29169')

        self.log_filename = log_filename
        self.shell_filename = shell_filename

    async def connect(self):
        async with self.logging_endpoint.lock, self.shell_endpoint.lock:
            await self.logging_endpoint.connect()
            await self.shell_endpoint.connect()

            self.log_file = await async_open(self.log_filename, 'a')
            self.shell_file = await async_open(self.shell_filename, 'a')

            self.logging_endpoint.start_read_loop(self.log_file.write)
            self.shell_endpoint.start_read_loop(self.shell_file.write)

    async def wait(self):
        await self.logging_endpoint.wait()
        await self.shell_endpoint.wait()

    async def disconnect(self):
        async with self.logging_endpoint.lock, self.shell_endpoint.lock:
            await self.logging_endpoint.stop_read_loop()
            await self.shell_endpoint.stop_read_loop()

            await self.log_file.close()
            await self.shell_file.close()

            await self.logging_endpoint.disconnect()
            await self.shell_endpoint.disconnect()