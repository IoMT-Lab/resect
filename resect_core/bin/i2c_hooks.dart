import 'package:renode/renode.dart';
import 'hook_util.dart';

Hook i2cInitHook = createHook(
  '''
i2cInitialize()
setReturnValue(cpu, 0)
''',
  scope: 'i2c',
  imports: ['set_return_value', 'sensor', 'i2c'],
);

Hook i2cWriteHook = createHook(
  '''
handleI2CWrite(cpu)
''',
  scope: 'i2c',
  imports: ['set_return_value', 'sensor', 'i2c'],
);

Hook i2cReadHook = createHook(
  '''
handleI2CRead(cpu)
''',
  scope: 'i2c',
  imports: ['set_return_value', 'sensor', 'i2c'],
);
