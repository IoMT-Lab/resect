REG_ENABLE = 0x80
REG_CONFIG = 0x70
REG_CFG0 = 0xA9
REG_LED = 0x74
REG_AUXID = 0x90
REG_REVID = 0x91
REG_ID = 0x92
REG_INTENAB = 0xF9
REG_STAT = 0x71
REG_STATUS = 0x93
REG_STATUS2 = 0xA3
REG_STATUS3 = 0xA4
REG_STATUS5 = 0xA6
REG_STATUS6 = 0xA7
REG_FD_STATUS = 0xDB
REG_CFG3 = 0xAC
REG_CH0_DATA_L = 0x95
REG_SP_TH_L_LSB = 0x84
REG_SP_TH_H_LSB = 0x86
REG_CONTROL = 0xFA

class GenericSensor:
    def __init__(self):
        pass

    def write(self, mem_address, data):
        print('Write - Mem Address: 0x{0:02X}, Data: {1}'.format(mem_address, data))

    def read(self, mem_address, size):
        print('Read - Mem Address: 0x{0:02X}, Size: {1}'.format(mem_address, size))
        return bytes([0x10, 0x20])

class AS7341:
    def __init__(self):
        self.registers = {
            REG_ENABLE: self.enable,
            REG_CONFIG: self.config,
            REG_CFG0: self.cfg0,
            REG_LED: self.led,
            REG_AUXID: self.auxid,
            REG_REVID: self.revid,
            REG_ID: self.id,
            REG_INTENAB: self.intenab,
            REG_STAT: self.stat,
            REG_STATUS: self.status,
            REG_STATUS2: self.status2,
            REG_STATUS3: self.status3,
            REG_STATUS5: self.status5,
            REG_STATUS6: self.status6,
            REG_FD_STATUS: self.fd_status,
            REG_CFG3: self.cfg3,
            REG_CH0_DATA_L: self.ch0_data,
            REG_SP_TH_L_LSB: self.sp_th_l,
            REG_SP_TH_H_LSB: self.sp_th_h,
            REG_CONTROL: self.control
        }

    def write(self, mem_address, data):
        print('Write')
        if mem_address in self.registers:
            self.registers[mem_address](data)
        else:
            print('I2C Write - Mem Address: 0x{0:02X} not handled'.format(mem_address))

    def read(self, mem_address, size):
        if mem_address in self.registers:
            return bytes(self.registers[mem_address]())
        else:
            print('I2C Read - Mem Address: 0x{0:02X} not handled'.format(mem_address))
            return bytes([0x00] * size)
    
    def enable(self, value=None):
        return 0x00

    def config(self, value=None):
        return 0x00

    def cfg0(self, value=None):
        return 0x00

    def led(self, value=None):
        return 0x00
    
    def auxid(self, value=None):
        return 0x00
    
    def revid(self, value=None):
        return 0x00

    def id(self, value=None):
        return 0x00

    def intenab(self, value=None):
        return 0x00
    
    def stat(self, value=None):
        return 0x00
    
    def status(self, value=None):
        return 0x00
    
    def status2(self, value=None):
        return 0x00
    
    def status3(self, value=None):
        return 0x00
    
    def status5(self, value=None):
        return 0x00
    
    def status6(self, value=None):
        return 0x00
    
    def fd_status(self, value=None):
        return 0x00
    
    def cfg3(self, value=None):
        return 0x00
    
    def ch0_data(self, value=None):
        return 0x00
    
    def sp_th_l(self, value=None):
        return 0x00
    
    def sp_th_h(self, value=None):
        return 0x00
    
    def control(self, value=None):
        return 0x00