import socket
import struct
import board

i2c = board.I2C()

msg_format = '!cII32p'  # Operation (1 byte), Device Address (4 bytes), Memory Address (4 bytes), Data (variable length)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('localhost', 12345))
print('Server listening on port 12345...')

while True:
    data, addr = s.recvfrom(1024)
    msg = struct.unpack(msg_format, data)
    operation, device_address, mem_address, data = msg
    
    if operation == b'R':
        buf = bytearray(len(data))
        i2c.writeto_then_readfrom(device_address >> 1, bytes([mem_address]), buf)
        # For read requests, send back dummy data (32 bytes of 0x00)
        response = struct.pack(msg_format, b'R', device_address, mem_address, buf)
        s.sendto(response, addr)

        print('Received Read request for device 0x{:02X}, mem address 0x{:02X} responding with data: {}'.format(
        device_address, mem_address, buf.hex()))
    elif operation == b'W':
        i2c.writeto(device_address >> 1, bytes([mem_address]) + data)
        print('Received Write request for device 0x{:02X}, mem address 0x{:02X} with data: {}'.format(
        device_address, mem_address, data.hex()))