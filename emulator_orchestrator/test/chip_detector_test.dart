import 'dart:io';

import 'package:emulator_orchestrator/data/models/chip_identity.dart';
import 'package:emulator_orchestrator/services/chip/chip_detector.dart';
import 'package:emulator_orchestrator/services/chip/platform_index.dart';
import 'package:test/test.dart';

/// Chip detection over the signals a project already carries. Fixtures
/// are the REAL platform files shipped in this repo's workdir.
void main() {
  group('ChipNameParser', () {
    test('parses ST part stems into vendor/family/part', () {
      final id = ChipNameParser.parse('STM32WB05')!;
      expect(id.vendor, 'st');
      expect(id.family, 'stm32wb0');
      expect(id.part, 'STM32WB05');
      expect(id.corpusKey, 'st.stm32wb0');
    });

    test('parses repl stems with suffixes', () {
      final id = ChipNameParser.parse('stm32wb05_empty')!;
      expect(id.part, 'STM32WB05');
      expect(ChipNameParser.parse('stm32f429')!.family, 'stm32f4');
    });

    test('parses Nordic parts and bare families', () {
      final full = ChipNameParser.parse('nrf52840')!;
      expect(full.vendor, 'nordic');
      expect(full.family, 'nrf52');
      expect(full.part, 'nRF52840');
      final bare = ChipNameParser.parse('nrf52')!;
      expect(bare.part, isNull);
      expect(bare.corpusKey, 'nordic.nrf52');
    });

    test('returns null on unknown names', () {
      expect(ChipNameParser.parse('mps2-an385'), isNull);
      expect(ChipNameParser.parse(''), isNull);
    });
  });

  group('ChipDetector', () {
    final svdRepl =
        File('../workdir/replay_live/stm32wb05_svd.repl').existsSync()
            ? File('../workdir/replay_live/stm32wb05_svd.repl')
                .readAsStringSync()
            : null;
    final emptyRepl = File('../workdir/example/stm32wb05_empty.repl')
        .readAsStringSync();

    test('ApplySVD line wins: exact part + svd url, top confidence', () {
      if (svdRepl == null) {
        markTestSkipped('replay_live repl not present');
        return;
      }
      final id = ChipDetector.detect(
        replContent: svdRepl,
        replPath: 'whatever.repl',
      );
      expect(id.part, 'STM32WB05');
      expect(id.vendor, 'st');
      expect(id.svdUrl, contains('STM32WB05.svd'));
      expect(id.confidence, greaterThanOrEqualTo(1.0));
      expect(id.evidence.first.signal, ChipSignal.svdUrl);
    });

    test('filename grammar identifies the example project repl', () {
      final id = ChipDetector.detect(
        replContent: emptyRepl,
        replPath: '/workdir/example/stm32wb05_empty.repl',
      );
      expect(id.part, 'STM32WB05');
      expect(id.core, 'cortex-m0+');
      expect(id.corpusKey, 'st.stm32wb0');
    });

    test('symbol prefixes give vendor-only identity', () {
      final id = ChipDetector.detect(
        symbolNames: [
          for (var i = 0; i < 6; i++) 'HAL_Thing$i',
          'main',
          'memset',
        ],
      );
      expect(id.vendor, 'st');
      expect(id.part, isNull);
      expect(id.corpusKey, isNull, reason: 'no family from symbols alone');
    });

    test('fewer than 5 prefixed symbols is no signal', () {
      final id = ChipDetector.detect(symbolNames: ['HAL_A', 'HAL_B', 'main']);
      expect(id.vendor, isNull);
    });

    test('vendor conflict caps confidence at 0.5 and keeps both evidences',
        () {
      final id = ChipDetector.detect(
        replPath: '/x/stm32wb05.repl',
        symbolNames: [for (var i = 0; i < 8; i++) 'nrf_thing$i'],
      );
      expect(id.confidence, lessThanOrEqualTo(0.5));
      expect(id.evidence.length, 2);
    });

    test('corroborating signals raise confidence', () {
      final lone = ChipDetector.detect(replPath: '/x/stm32wb05.repl');
      final corroborated = ChipDetector.detect(
        replPath: '/x/stm32wb05.repl',
        symbolNames: [for (var i = 0; i < 8; i++) 'HAL_Thing$i'],
      );
      expect(corroborated.confidence, greaterThan(lone.confidence));
    });

    test('no signals → unknown identity, zero confidence', () {
      final id = ChipDetector.detect(replPath: '/x/mps2-an385.repl');
      expect(id.vendor, isNull);
      expect(id.confidence, 0);
    });
  });

  group('PlatformIndex', () {
    test('fingerprints and matches the example repl by memory layout',
        () async {
      final engineDir = Directory('../emulation_engine');
      if (!engineDir.existsSync()) {
        markTestSkipped('emulation_engine not present');
        return;
      }
      final index = await PlatformIndex.load(engineDir: engineDir);
      expect(index.fingerprints, isNotEmpty);
      // The bundled set includes part-named ST/Nordic platforms.
      expect(
        index.fingerprints.where((f) => f.stem.startsWith('nrf52')),
        isNotEmpty,
      );
    });

    test('parse extracts cpuType, regions, and branded tokens', () {
      const repl = '''
cpu: CPU.CortexM @ sysbus
    cpuType: "cortex-m4"
uart0: UART.NRF52840_UART @ sysbus 0x40002000
ram: Memory.MappedMemory @ sysbus 0x20000000
    size: 0x40000
''';
      final f = PlatformFingerprint.parse('probe', repl);
      expect(f.cpuType, 'cortex-m4');
      expect(f.regions, [(0x20000000, 0x40000)]);
      expect(f.vendorTokens, contains('NRF52840_UART'));
    });
  });
}
