import socket
import struct

msg_format = '!cII32p'  # Operation (1 byte), Device Address (4 bytes), Memory Address (4 bytes), Data (variable length)

def extractParams(cpu):
    # i2c_handle = cpu.GetRegister(0).RawValue
    device_address = int(cpu.GetRegister(1).RawValue)
    mem_address = int(cpu.GetRegister(2).RawValue)
    stack_pointer = cpu.SP.RawValue

    data_pointer_bytes = cpu.Bus.ReadBytes(stack_pointer, 4)
    size_bytes = bytes(cpu.Bus.ReadBytes(stack_pointer + 4, 4))

    data_pointer = struct.unpack('<I', data_pointer_bytes)[0]
    size = struct.unpack('<I', size_bytes)[0]
    return device_address, mem_address, data_pointer, size

def readData(cpu, data_pointer, size):
    return bytes(cpu.Bus.ReadBytes(data_pointer, size))

def writeData(cpu, data_pointer, data):
    from System import Array, Byte # type: ignore
    cpu.Bus.WriteBytes(Array[Byte](list(data)), data_pointer)

def sendData(device_address, mem_address, data):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    msg = struct.pack(msg_format, b'W', device_address, mem_address, data)
    s.sendto(msg, ('localhost', 12345))
    s.close()

def receiveData(device_address, mem_address, size):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    msg = struct.pack(msg_format, b'R', device_address, mem_address, b'\0' * size)
    s.sendto(msg, ('localhost', 12345))
    resp = s.recv(1024)
    s.close()
    _, _, _, data = struct.unpack(msg_format, resp)
    return bytes(data)

def handleI2CRead(cpu):
    device_address, mem_address, data_pointer, size = extractParams(cpu)
    data = receiveData(device_address, mem_address, size)
    writeData(cpu, data_pointer, data)
    setReturnValue(cpu, 0)  # type: ignore # Success

def handleI2CWrite(cpu):
    device_address, mem_address, data_pointer, size = extractParams(cpu)
    data = readData(cpu, data_pointer, size)
    sendData(device_address, mem_address, data)
    setReturnValue(cpu, 0)  # type: ignore # Success