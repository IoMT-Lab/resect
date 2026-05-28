import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as m;
import 'package:emulator_orchestrator/data/services/comms_classifier.dart';
import 'package:test/test.dart';

CallGraph _graphOf(Iterable<String> names) => CallGraph(
      elfPath: '/dev/null',
      symbols: {
        for (final n in names)
          n: m.Symbol(name: n, numInstructions: 1, calledSymbols: const {}),
      },
    );

void main() {
  const classifier = NamePatternCommsClassifier();

  group('protocol detection', () {
    test('STM HAL i2c names → i2c', () {
      final r = classifier.classify(_graphOf(['HAL_I2C_Master_Transmit']));
      expect(r['HAL_I2C_Master_Transmit']?.protocol, CommsClass.i2c);
    });

    test('STM LL spi names → spi', () {
      final r = classifier.classify(_graphOf(['LL_SPI_TransmitData8']));
      expect(r['LL_SPI_TransmitData8']?.protocol, CommsClass.spi);
    });

    test('STM HAL UART and USART names → uart', () {
      final r = classifier.classify(_graphOf([
        'HAL_UART_Transmit',
        'HAL_USART_Receive',
      ]));
      expect(r['HAL_UART_Transmit']?.protocol, CommsClass.uart);
      expect(r['HAL_USART_Receive']?.protocol, CommsClass.uart);
    });

    test('Nordic, ESP-IDF, NXP, lowercase generic — all match via substring', () {
      final r = classifier.classify(_graphOf([
        'nrf_drv_i2c_init',
        'i2c_master_write_to_device',
        'LPI2C_MasterReceive',
        'spi_master_transmit',
        'uart_send_bytes',
      ]));
      expect(r['nrf_drv_i2c_init']?.protocol, CommsClass.i2c);
      expect(r['i2c_master_write_to_device']?.protocol, CommsClass.i2c);
      expect(r['LPI2C_MasterReceive']?.protocol, CommsClass.i2c);
      expect(r['spi_master_transmit']?.protocol, CommsClass.spi);
      expect(r['uart_send_bytes']?.protocol, CommsClass.uart);
    });

    test('non-comms symbols are not surfaced (out of Comms tab entirely)', () {
      final r = classifier.classify(_graphOf([
        'SystemInit',
        'main',
        'HAL_RCC_OscConfig',
      ]));
      expect(r, isEmpty);
    });
  });

  group('role detection', () {
    test('Receive/Read/Get → read', () {
      final r = classifier.classify(_graphOf([
        'HAL_I2C_Master_Receive',
        'i2c_master_read_from_device',
        'spi_get_status',
      ]));
      expect(r['HAL_I2C_Master_Receive']?.role, CommsRole.read);
      expect(r['i2c_master_read_from_device']?.role, CommsRole.read);
      expect(r['spi_get_status']?.role, CommsRole.read);
    });

    test('Transmit/Write/Send/Put → write', () {
      final r = classifier.classify(_graphOf([
        'HAL_I2C_Master_Transmit',
        'i2c_master_write_to_device',
        'uart_send_bytes',
        'spi_put_byte',
      ]));
      expect(r['HAL_I2C_Master_Transmit']?.role, CommsRole.write);
      expect(r['i2c_master_write_to_device']?.role, CommsRole.write);
      expect(r['uart_send_bytes']?.role, CommsRole.write);
      expect(r['spi_put_byte']?.role, CommsRole.write);
    });

    test('protocol-matched but role-ambiguous → role is null', () {
      final r = classifier.classify(_graphOf([
        'HAL_I2C_Init',
        'spi_deinit',
        'uart_enable',
      ]));
      expect(r['HAL_I2C_Init']?.protocol, CommsClass.i2c);
      expect(r['HAL_I2C_Init']?.role, isNull);
      expect(r['spi_deinit']?.protocol, CommsClass.spi);
      expect(r['spi_deinit']?.role, isNull);
      expect(r['uart_enable']?.protocol, CommsClass.uart);
      expect(r['uart_enable']?.role, isNull);
    });
  });

  test('case-insensitive matching', () {
    final r = classifier.classify(_graphOf(['HAL_i2c_TX', 'mY_SPI_thing']));
    expect(r['HAL_i2c_TX']?.protocol, CommsClass.i2c);
    expect(r['mY_SPI_thing']?.protocol, CommsClass.spi);
  });

  test('does not invent assignments for the unclassified bucket', () {
    // `unclassified` is reserved for user-moved items; the classifier itself
    // never emits it (it just omits non-matching symbols).
    final r = classifier.classify(_graphOf([
      'main',
      'init_clocks',
      'do_stuff',
    ]));
    expect(r.values.any((a) => a.protocol == CommsClass.unclassified), isFalse);
    expect(r, isEmpty);
  });
}
