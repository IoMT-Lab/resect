# RETAINED — NOT USED BY THE APP.
# This Python emulation engine has been superseded by the in-process Dart engine
# (renode-dart + callgraph-dart); the resect app/CLI no longer launches it.
# It is kept here for two reasons:
#   1. it is vendored in the same directory as the Renode portable binary
#      (../renode_1.16.0-dotnet_portable/), which the Dart engine still uses, and
#   2. the Vagrant CI harness (emulator_orchestrator/lib/orchestrator/
#      vagrant_test_runner.dart) still provisions it via this dir's Pipfile.
# Safe to delete once that harness is reworked to exercise the Dart CLI instead.

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
