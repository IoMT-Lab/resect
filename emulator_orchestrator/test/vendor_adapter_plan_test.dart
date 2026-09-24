import 'package:emulator_orchestrator/data/models/chip_identity.dart';
import 'package:emulator_orchestrator/services/corpus/vendor_adapter.dart';
import 'package:emulator_orchestrator/services/corpus/vendor_adapter_registry.dart';
import 'package:test/test.dart';

/// Adapter plans are pure functions over curated tables — these goldens
/// pin the exact sources v1 fetches. Zero network.
void main() {
  ChipIdentity wb05({String? svdUrl}) => ChipIdentity(
        vendor: 'st',
        family: 'stm32wb0',
        part: 'STM32WB05',
        svdUrl: svdUrl,
        confidence: 1,
      );

  test('registry resolves ST and declines unknown vendors', () {
    expect(adapterFor(wb05())?.id, 'st');
    expect(adapterFor(const ChipIdentity(vendor: 'nxp', family: 'imxrt')),
        isNull);
    expect(adapterFor(const ChipIdentity(vendor: 'st', family: 'stm32zz9')),
        isNull, reason: 'family without curated sources');
  });

  test('STM32WB05 plan: HAL + CMSIS submodule tarballs, SVD, RM', () {
    final plan = adapterFor(wb05())!.plan(wb05());
    expect(plan.corpusKey, 'st.stm32wb0');

    final sdks =
        plan.items.where((i) => i.kind == CorpusItemKind.sdkSource).toList();
    // Two SDK items: the HAL driver and CMSIS device submodule repos —
    // the umbrella STM32Cube repo vendors these as submodules whose tag
    // tarball is empty, so we fetch them directly.
    expect(sdks.map((s) => s.url.toString()).toList(), [
      'https://codeload.github.com/STMicroelectronics/stm32wb0x_hal_driver/tar.gz/refs/heads/main',
      'https://codeload.github.com/STMicroelectronics/cmsis_device_wb0/tar.gz/refs/heads/main',
    ]);
    expect(sdks.first.keep.map((k) => k.glob), contains('*/Src/*.c'));
    expect(sdks.last.keep.map((k) => k.glob), contains('*/Include/*.h'));
    for (final s in sdks) {
      expect(s.optional, isFalse);
      expect(s.licenseNote, isNotEmpty);
    }

    final svd = plan.items.singleWhere((i) => i.kind == CorpusItemKind.svd);
    expect(svd.url.toString(), contains('modm-io/cmsis-svd-stm32'));
    expect(svd.url.toString(), endsWith('stm32wb0/STM32WB05.svd'));
    expect(svd.part, 'STM32WB05');

    final rm = plan.items
        .singleWhere((i) => i.kind == CorpusItemKind.referenceManualPdf);
    expect(rm.optional, isTrue, reason: 'PDF failure must not fail the fetch');
    expect(rm.url.toString(), contains('rm0505'));
  });

  test('detected ApplySVD URL is used verbatim over the mirror pattern', () {
    const detected = 'https://example.com/exact/STM32WB05.svd';
    final plan = adapterFor(wb05())!.plan(wb05(svdUrl: detected));
    final svd = plan.items.singleWhere((i) => i.kind == CorpusItemKind.svd);
    expect(svd.url.toString(), detected);
  });

  test('family-only identity plans the SDK and notes the missing SVD/PDF',
      () {
    const familyOnly =
        ChipIdentity(vendor: 'st', family: 'stm32f4', confidence: 0.6);
    final plan = adapterFor(familyOnly)!.plan(familyOnly);
    // Two SDK submodule items, no SVD (part unknown), no PDF.
    expect(plan.items.map((i) => i.kind),
        everyElement(CorpusItemKind.sdkSource));
    expect(plan.items, hasLength(2));
    expect(plan.notes.join(' '), contains('no SVD'));
    expect(plan.notes.join(' '), contains('drop_in'));
  });

  test('plan JSON round-trips the consent-relevant fields', () {
    final json = adapterFor(wb05())!.plan(wb05()).toJson();
    expect(json['corpus_key'], 'st.stm32wb0');
    final items = json['items'] as List;
    expect(items, isNotEmpty);
    for (final i in items.cast<Map<String, dynamic>>()) {
      expect(i['url'], isNotEmpty);
      expect(i['license_note'], isNotEmpty);
    }
  });
}
