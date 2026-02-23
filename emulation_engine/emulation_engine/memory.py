from typing import Any
import base64

class Snapshot:
    def __init__(self, registers: dict[int, int], memory: dict[int, bytes]):
        self.registers = registers
        self.memory = memory

    def to_dict(self):
        return {
            'registers': self.registers,
            'memory': {addr: base64.b64encode(data).decode('utf-8') for addr, data in self.memory.items()}
        }
    
    @classmethod
    def from_dict(cls, data: dict[str, Any]):
        registers = data.get('registers', {})
        memory = {int(addr): base64.b64decode(data) for addr, data in data.get('memory', {}).items()}
        return Snapshot(registers, memory)