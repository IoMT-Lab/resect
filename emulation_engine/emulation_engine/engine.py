
import asyncio
import os

from .transport.server.server import Server
import logging

def main():
    logging.basicConfig(level=logging.INFO)

    renode_path = os.getenv('RENODE_EXECUTABLE', 'renode')
    renode_port = int(os.getenv('RENODE_PORT', 5000))
    server_port = int(os.getenv('SERVER_PORT', 12356))
    logging_path = os.getenv('LOGGING_PATH', '/tmp/renode_logs')

    server = Server(renode_path, renode_port, logging_path)
    server.listen(server_port)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Exiting program')
