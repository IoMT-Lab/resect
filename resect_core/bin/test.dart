import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:renode/renode.dart';

import 'hook_util.dart';
import 'i2c_hooks.dart';
import 'simple_hooks.dart';

const renodePath = '../exclude/renode_1.16.1+20260512gitf8adfbff0-portable/renode';
const renodePort = 5678;
const replPath = '../exclude/stm32wb05_nosvd.repl';
const firmwarePath = '../exclude/aya_ppg.elf';

RenodeProcess? process;
RenodeClient? client;
String? lastFunction;

const prettyJsonEncoder = JsonEncoder.withIndent('  ');

Future<void> main(List<String> args) async {
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.INFO; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  try {
    loadImports();
    await setup();
    await createMachine();
    await addHooks();
    await freshStart();
    await Future.delayed(Duration(seconds: 15)); // Run for a while to capture events
  } finally {
    await teardown();
  }
}

Future<void> freshStart() async {
  await client?.run(endAt: ['Error_Handler']);
}

Future<void> hotload() async {
  final file = File('hal_i2c_mem_write_snapshot.json');
  await file.readAsString().then((content) async {
    final snapshot = Snapshot.fromJson(jsonDecode(content));
    await client?.restore(snapshot);
  });
  await client?.run(startFrom: 'HAL_I2C_Mem_Write', endAt: ['Error_Handler']);
}

Future<void> setup() async {
  final stdoutSink = stdout;
  final stderrSink = stderr;
  process = RenodeProcess(renodePath, renodePort, stdoutSink, stderrSink);
  await process?.start();

  client = await RenodeClient.connect('localhost', renodePort);
  client?.onStateChanged.listen(handleStateChange);
  client?.onFunctionCalled.listen(handleFunctionCall);
  client?.onUnhandledAccess.listen(handleUnhandledAccess);

  await client?.enableTracing(disallowedPrefixes: ['HAL_GetTick', 'UTIL_SEQ', 'SEQ_BitPosition', 'DoSomething', 'SysTick_Handler', 'HAL_IncTick']);
}

Future<void> createMachine() async {
  await fileToBase64(replPath).then((value) => client?.createMachine(value));
  await fileToBase64(firmwarePath).then((value) => client?.loadFirmware(value));
}

Future<void> addHooks() async {
  await client?.addHooks({
    'SystemInit': returnHook(0),
    'LL_APB0_GRP1_EnableClock': returnHook(0),
    'LL_RCC_HSE_SetCapacitorTuning': returnHook(0),
    'LL_RCC_HSE_SetCurrentControl': returnHook(0),

    'LL_RCC_HSE_Enable': writeHook('hse_status', 1),
    'LL_RCC_HSE_Disable': writeHook('hse_status', 0),
    'LL_RCC_HSE_IsReady': readHook('hse_status'),

    'LL_RCC_HSI_Enable': writeHook('hsi_status', 1),
    'LL_RCC_HSI_Disable': writeHook('hsi_status', 0),
    'LL_RCC_HSI_IsReady': readHook('hsi_status'),

    'LL_RCC_LSI_Enable': writeHook('lsi_status', 1),
    'LL_RCC_LSI_Disable': writeHook('lsi_status', 0),
    'LL_RCC_LSI_IsReady': readHook('lsi_status'),

    'LL_RCC_LSE_Enable': writeHook('lse_status', 1),
    'LL_RCC_LSE_Disable': writeHook('lse_status', 0),
    'LL_RCC_LSE_IsReady': readHook('lse_status'),

    'LL_RCC_LSCO_SetSource': returnHook(0),
    'HAL_RCC_ClockConfig': returnHook(0),
    'LL_RCC_SetSMPSPrescaler': returnHook(0),
    'LL_AHB1_GRP1_EnableClock': returnHook(0),
    'HAL_GPIO_Init': returnHook(0),
    'HAL_PWREx_EnableGPIOPullUp': returnHook(0),
    'HAL_PWREx_DisableGPIOPullUp': returnHook(0),
    'HAL_PWREx_DisableGPIOPullDown': returnHook(0),
    'LL_APB1_GRP1_EnableClock': returnHook(0),

    'HAL_RNG_Init': returnHook(0),
    'LL_APB2_GRP1_IsEnabledClock': returnHook(1),
    'HAL_RADIO_Init': returnHook(0),

    'LL_RADIO_TIMER_GetAbsoluteTime': incrementHook('radio_timer'),

    'LL_RADIO_TIMER_ClearFlag_CPUWakeup': returnHook(0),
    'LL_RADIO_TIMER_EnableCPUWakeupIT': returnHook(0),
    'LL_RADIO_TIMER_IsActiveFlag_LSICalibrationEnded': returnHook(1),
    'LL_RADIO_TIMER_SetLSIWindowCalibrationLength': returnHook(0),
    'LL_RADIO_TIMER_ClearFlag_LSICalibrationEnded': returnHook(0),
    'LL_RADIO_TIMER_StartLSICalibration': returnHook(0),
    'LL_RADIO_TIMER_GetLSIPeriod': returnHook(100),
    'LL_RADIO_TIMER_GetLSIFrequency': returnHook(100),
    'LL_RADIO_TIMER_SetWakeupOffset': returnHook(0),
    'LL_RADIO_TIMER_SetCPUWakeupTime': returnHook(0),
    'LL_RADIO_TIMER_EnableWakeupTimerLowPowerMode': returnHook(0),
    'LL_RADIO_TIMER_EnableCPUWakeupTimer': returnHook(0),
    'HAL_PKA_Init': returnHook(0),
    'HAL_UART_Init': returnHook(0),
    'HAL_UARTEx_SetTxFifoThreshold': returnHook(0),
    'HAL_UARTEx_SetRxFifoThreshold': returnHook(0),
    'HAL_UARTEx_DisableFifoMode': returnHook(0),
    'HW_RNG_Init': returnHook(0),
    'HW_PKA_Init': returnHook(0),
    'LL_RADIO_TIMER_DisableTimer1': returnHook(0),
    'LL_RADIO_TIMER_DisableTimer2': returnHook(0),
    'LL_RADIO_TIMER_DisableBLEWakeupTimer': returnHook(0),
    'LL_RADIO_BlueSetInterrupt1RegRegister': returnHook(0),
    'LL_SYSCFG_GetDeviceJTAG_ID': returnHook(0),
    'LL_SYSCFG_GetDeviceVersion': returnHook(0),
    'LL_SYSCFG_GetDeviceRevision': returnHook(0),
    'LL_GetFlashSize': returnHook(128 * 1024),
    'LL_PWR_IsEnabledSMPSPrechargeMode': returnHook(0),
    'LL_PWR_GetSMPSMode': returnHook(0),
    'LL_PWR_SetSMPSPrechargeMode': returnHook(0),
    'LL_PWR_IsSMPSReady': returnHook(0),
    'RADIO_SetHighPower': returnHook(0),
    'HW_RNG_GetRandom16': returnHook(0x1234),

    'hci_le_set_advertising_parameters': returnHook(0),
    'LL_RADIO_BlueSetClearSemaphoreRequest': returnHook(0),
    'LL_RADIO_TIMER_SetTimeout': returnHook(0),
    'LL_RADIO_TIMER_EnableTimer1': returnHook(0),
    'HAL_RADIO_TIMER_GetAnchorPoint': returnHook(0),
    'HW_RNG_GetRandom32': returnHook(0x12345678),
    'HAL_Delay': returnHook(0),

    'MX_I2C1_Init': returnHook(0),
    'HAL_I2C_Mem_Read': i2cReadHook,
    'HAL_I2C_Mem_Write': i2cWriteHook,
  });
}

Future<void> handleStateChange(StateChangeEvent event) async {
  print('State changed: ${event.state}');
  if (event.state == State.paused) {
    print('Last function called: $lastFunction');
    if (lastFunction == 'HAL_I2C_Mem_Read') {
      final snapshot = await client?.save({0x20000000: 0x6000});
      final file = File('hal_i2c_mem_read_snapshot.json');
      await file.writeAsString(prettyJsonEncoder.convert(snapshot));
    } else if (lastFunction == 'HAL_I2C_Mem_Write') {
      print('Inspecting I2C write state...');
      final snapshot = await client?.save({0x20000000: 0x6000});
      final file = File('hal_i2c_mem_write_snapshot.json');
      await file.writeAsString(prettyJsonEncoder.convert(snapshot));
    }
  }
}

Future<void> handleFunctionCall(FunctionCallEvent event) async {
  print('Function called: ${event.name}, isEntry: ${event.isEntry}');
  lastFunction = event.name;
}

Future<void> handleUnhandledAccess(UnhandledAccessEvent event) async {
  print(
    'Unhandled access: ${event.name}, PC: ${event.programCounter}, isWrite: ${event.isWrite}, address: ${event.address}, width: ${event.width}, value: ${event.value}',
  );
}

Future<void> teardown() async {
  await client?.dispose();
  await process?.stop();
}

Future<Base64Data> fileToBase64(String path) async {
  // 1. Create a File object from the path
  final file = File(path);

  // 2. Read the file as bytes (asynchronously)
  final fileBytes = await file.readAsBytes();
  return Base64Data.fromBytes(fileBytes);
}
