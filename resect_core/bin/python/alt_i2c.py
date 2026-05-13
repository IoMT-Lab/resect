def i2cInitialize():
    if not globals().get('i2c_initialized', False):
        globals()['i2c_initialized'] = True
        globals()['i2c_devices'] = {}
        globals()['i2c_devices'][0x72] = AS7341() # type: ignore

def extractParams(cpu):
    import struct
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

def handleI2CRead(cpu):
    device_address, mem_address, data_pointer, size = extractParams(cpu)

    if device_address not in globals().get('i2c_devices', {}):
        print('I2C Read - Device: 0x{:02X} not found'.format(device_address))
        setReturnValue(cpu, 1)  # type: ignore # Device not found
    else:
        device = globals()['i2c_devices'][device_address]
        data = device.read(mem_address, size)
        writeData(cpu, data_pointer, data)
        setReturnValue(cpu, 0)  # type: ignore # Success

def handleI2CWrite(cpu):
    device_address, mem_address, data_pointer, size = extractParams(cpu)
    data = readData(cpu, data_pointer, size)

    if device_address not in globals().get('i2c_devices', {}):
        print('I2C Write - Device: 0x{:02X} not found'.format(device_address))
        setReturnValue(cpu, 1)  # type: ignore # Device not found
    else:
        device = globals()['i2c_devices'][device_address]
        device.write(mem_address, data)
        setReturnValue(cpu, 0)  # type: ignore # Success
