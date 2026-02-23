import os, re
import asyncio

import logging
logger = logging.getLogger(__name__)

SYMBOL_PATTERN = re.compile(r'^(?xi:[a-f0-9]+)\s+([lgu\! ])([w ])([C ])([W ])([Ii ])([dD ])([FfO ])\s+(\S+)\s+(?xi:[a-f0-9]+)\s+(.hidden\s+)?(\S+)$')
ASSEMBLY_CALL_PATTERN = re.compile(r'^\s+bl\s+<([^>]+)>')

class ARMCallgraph:
    def __init__(self, objdump = os.getenv('ARM_OBJDUMP', 'arm-none-eabi-objdump')):
        self.objdump = objdump
        logger.info(f"Initialized ARMCallgraph with objdump: {self.objdump}")

    async def extract_symbols(self, filename: str):
        logger.info(f"Extracting symbols from file: {filename}")
        if not os.path.exists(filename):
            logger.warning(f"File not found: {filename}")
            return False, "Path not found"
        
        return True, list(await self._extract_symbols(filename))

    async def generate_callgraph(self, filename):
        logger.info(f"Generating callgraph for file: {filename}")
        if not os.path.exists(filename):
            logger.warning(f"File not found: {filename}")
            return False, "Path not found"
        
        symbols = await self._extract_symbols(filename)
        callgraph = {}
        for symbol in symbols:
            num_instructions, called_symbols = await self._process_symbol(filename, symbol)
            callgraph[symbol] = {
                "num_instructions": num_instructions,
                "called_symbols": called_symbols
            }
        return True, callgraph
    
    async def _extract_symbols(self, filename):
        symbols = set()
        proc = await asyncio.create_subprocess_exec(self.objdump, '--syms', filename, stdout=asyncio.subprocess.PIPE)
        async for line in proc.stdout:
            line = line.decode().strip()
            m = SYMBOL_PATTERN.match(line)
            if m and m.group(7) == 'F':
                symbols.add(m.group(10))
        return symbols
    
    async def _process_symbol(self, filename, symbol):
        called_symbols = {}
        proc = await asyncio.create_subprocess_exec(self.objdump, f'--disassemble={symbol}', '--no-addresses', '--section=.text', '--no-show-raw-insn', filename, stdout=asyncio.subprocess.PIPE)
        num_instructions = -5 # Subtract header/footer lines
        async for line in proc.stdout:
            line = line.decode()
            num_instructions += 1
            m = ASSEMBLY_CALL_PATTERN.search(line)
            if m:
                function_call = m.group(1)
                if function_call in called_symbols:
                    called_symbols[function_call] += 1
                else:
                    called_symbols[function_call] = 1
        return num_instructions, called_symbols

