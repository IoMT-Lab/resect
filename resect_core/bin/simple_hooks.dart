import 'package:renode/renode.dart';
import 'hook_util.dart';

Hook returnHook(int returnValue) => createHook(
  '''
setReturnValue(cpu, $returnValue)''',
  imports: ['set_return_value'],
);

Hook writeHook(String scope, int value, {returnValue = 0}) => createHook(
  '''
setVariable('value', $value)
setReturnValue(cpu, $returnValue)
''',
  scope: scope,
  imports: ['set_return_value', 'variables'],
);

Hook readHook(String scope, {int defaultValue = 0}) => createHook(
  '''
retValue = getVariable('value', $defaultValue)
setReturnValue(cpu, retValue)
''',
  scope: scope,
  imports: ['set_return_value', 'variables'],
);

Hook incrementHook(String scope, {int defaultValue = 0}) => createHook(
  '''
incrementVariable('value', $defaultValue)
retValue = getVariable('value')
setReturnValue(cpu, retValue)
''',
  scope: scope,
  imports: ['set_return_value', 'variables'],
);
