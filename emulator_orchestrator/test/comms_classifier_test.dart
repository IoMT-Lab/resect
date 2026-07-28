import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as m;
import 'package:emulator_orchestrator/services/comms/comms_classifier.dart';
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

  group('false-positive rejection (token-aware matching)', () {
    test('HAL_MspInit: "spi" only via Msp+Init overlap → no match', () {
      // The original report: HAL_MspInit was being classified as SPI.
      final r = classifier.classify(_graphOf(['HAL_MspInit']));
      expect(r, isEmpty);
    });

    test('CamelCase symbols where the protocol substring spans tokens', () {
      // 'Msp' + 'Init' → tokens [Msp, Init], no spi token.
      // 'inspect' as a token by itself contains "spe" but not "spi" anyway;
      // the realistic case is the 'Msp|Init' overlap above.
      final r = classifier.classify(_graphOf([
        'PostMspInit',           // Post + Msp + Init
        'DispatchMspHandler',    // Dispatch + Msp + Handler
      ]));
      expect(r, isEmpty);
    });

    test('quartz_init / quarterly_callback: "uart" inside "quart" → no match', () {
      final r = classifier.classify(_graphOf([
        'quartz_init',
        'quarterly_callback',
      ]));
      expect(r, isEmpty);
    });

    test('SPINNER and similar SPI-prefixed words → no match', () {
      // All-uppercase, starts with SPI but doesn't end with SPI; the
      // acronym-suffix rule requires the protocol literal at the END.
      final r = classifier.classify(_graphOf([
        'SPINNER',
        'SPINNER_init',
      ]));
      expect(r, isEmpty);
    });

    test('LPSPI and friends: acronym-suffix rule matches NXP-style names', () {
      // Vendor-prefixed all-caps acronyms (1–3 letter prefix) still match.
      final r = classifier.classify(_graphOf([
        'LPSPI_MasterTransmit',
        'LPI2C_MasterReceive',
        'LPUART_Init',
        'HSI2C_Read',
      ]));
      expect(r['LPSPI_MasterTransmit']?.protocol, CommsClass.spi);
      expect(r['LPI2C_MasterReceive']?.protocol, CommsClass.i2c);
      expect(r['LPUART_Init']?.protocol, CommsClass.uart);
      expect(r['HSI2C_Read']?.protocol, CommsClass.i2c);
    });

    test('peripheral-index suffixes are stripped: USART1 / SPI4 / I2C3 match', () {
      final r = classifier.classify(_graphOf([
        'USART1_IRQHandler',
        'SPI4_Init',
        'I2C3_Receive',
      ]));
      expect(r['USART1_IRQHandler']?.protocol, CommsClass.uart);
      expect(r['SPI4_Init']?.protocol, CommsClass.spi);
      expect(r['I2C3_Receive']?.protocol, CommsClass.i2c);
    });

    test('role: "Ready" does NOT count as read (was a substring false positive)', () {
      // HAL_I2C_IsDeviceReady is i2c-classified but its role should be null —
      // "Ready" is its own token, distinct from "Read".
      final r = classifier.classify(_graphOf(['HAL_I2C_IsDeviceReady']));
      expect(r['HAL_I2C_IsDeviceReady']?.protocol, CommsClass.i2c);
      expect(r['HAL_I2C_IsDeviceReady']?.role, isNull);
    });
  });

  group('tokenize', () {
    test('snake_case splits on underscores', () {
      expect(tokenize('foo_bar_baz'), ['foo', 'bar', 'baz']);
    });

    test('CamelCase splits on lower→Upper boundaries', () {
      expect(tokenize('LcdSpiInit'), ['Lcd', 'Spi', 'Init']);
    });

    test('all-caps acronym followed by CamelCase: split before the new word', () {
      expect(tokenize('LPSPIMasterTransmit'), ['LPSPI', 'Master', 'Transmit']);
    });

    test('mixed snake + CamelCase', () {
      expect(
        tokenize('HAL_I2C_MasterTransmit'),
        ['HAL', 'I2C', 'Master', 'Transmit'],
      );
    });

    test('runs of all-caps without a trailing lowercase stay intact', () {
      expect(tokenize('LPSPI'), ['LPSPI']);
      expect(tokenize('USART1'), ['USART1']);
    });
  });
}
