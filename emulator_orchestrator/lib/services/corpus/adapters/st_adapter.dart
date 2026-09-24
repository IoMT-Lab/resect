import '../../../data/models/chip_identity.dart';
import '../vendor_adapter.dart';

/// STMicroelectronics: HAL driver + CMSIS device headers (GitHub) +
/// CMSIS-SVD register maps (modm-io mirror) + curated reference-manual
/// PDFs.
///
/// IMPORTANT: the umbrella `STM32CubeXX` repos vendor the HAL driver and
/// CMSIS device headers as git SUBMODULES, so their GitHub tag tarball
/// ships empty placeholders — not the source. We fetch the standalone
/// submodule repos directly instead (`stm32wb0x_hal_driver`,
/// `cmsis_device_wb0`), whose tarballs carry the real `Src/*.c`,
/// `Inc/*.h`, and `Include/*.h`. Verified against the live repos on
/// 2026-08-28. `modm-io/cmsis-svd-stm32` main pinned at e79021ac…
/// (`stm32wb0/STM32WB05.svd`). Tarballs come from codeload.github.com —
/// plain HTTPS, no git binary.
class StAdapter extends VendorCorpusAdapter {
  const StAdapter();

  @override
  String get id => 'st';

  @override
  int get version => 2;

  @override
  Set<String> get symbolPrefixes => const {'HAL_', 'LL_', '__HAL_'};

  static const _svdRepoCommit = 'e79021accd49bf19bd0b16065f5471fb073ff3ac';

  /// family → (HAL driver repo, CMSIS device repo). Both are fetched at
  /// their default branch (`main`), the pinned unit of these
  /// continuously-tagged mirrors. Verified to contain real source on
  /// 2026-08-28.
  static const _families = <String, (String, String)>{
    'stm32wb0': ('stm32wb0x_hal_driver', 'cmsis_device_wb0'),
    'stm32f4': ('stm32f4xx_hal_driver', 'cmsis_device_f4'),
    'stm32wb': ('stm32wbxx_hal_driver', 'cmsis_device_wb'),
    'stm32l4': ('stm32l4xx_hal_driver', 'cmsis_device_l4'),
    'stm32g4': ('stm32g4xx_hal_driver', 'cmsis_device_g4'),
  };

  /// Curated per-part document URLs (reference manual, datasheet).
  /// Sparse by design: a missing part degrades to an honest plan note,
  /// never a guessed URL.
  static const _partPdfs = <String, List<(String, String, CorpusItemKind)>>{
    'STM32WB05': [
      (
        'rm:rm0505',
        'https://www.st.com/resource/en/reference_manual/rm0505-stm32wb05xz-armbased-wireless-mcu-with-bluetooth-low-energy-radio-stmicroelectronics.pdf',
        CorpusItemKind.referenceManualPdf,
      ),
    ],
  };

  @override
  bool canHandle(ChipIdentity chip) =>
      chip.vendor == id && _families.containsKey(chip.family);

  @override
  FetchPlan plan(ChipIdentity chip) {
    final family = chip.family!;
    final (halRepo, cmsisRepo) = _families[family]!;
    final items = <FetchItem>[];
    final notes = <String>[];

    // HAL driver source (standalone submodule repo, default branch).
    items.add(FetchItem(
      key: 'sdk:$halRepo',
      url: Uri.parse(
          'https://codeload.github.com/STMicroelectronics/$halRepo/tar.gz/refs/heads/main'),
      kind: CorpusItemKind.sdkSource,
      approxBytes: 6 * 1024 * 1024,
      licenseNote: 'ST HAL driver — BSD-3-Clause; cached locally, never '
          'redistributed',
      keep: const [
        ExtractRule('*/Src/*.c'),
        ExtractRule('*/Inc/*.h'),
      ],
    ));
    // CMSIS device headers (register defs, memory map).
    items.add(FetchItem(
      key: 'sdk:$cmsisRepo',
      url: Uri.parse(
          'https://codeload.github.com/STMicroelectronics/$cmsisRepo/tar.gz/refs/heads/main'),
      kind: CorpusItemKind.sdkSource,
      approxBytes: 4 * 1024 * 1024,
      licenseNote: 'ST CMSIS device — Apache-2.0; cached locally, never '
          'redistributed',
      keep: const [
        ExtractRule('*/Include/*.h'),
      ],
    ));

    // SVD: the detector's ApplySVD URL verbatim when present (exact
    // part), else the pinned modm-io mirror path for the part.
    final part = chip.part;
    if (chip.svdUrl != null) {
      items.add(FetchItem(
        key: 'svd:${part ?? family}',
        url: Uri.parse(chip.svdUrl!),
        kind: CorpusItemKind.svd,
        approxBytes: 512 * 1024,
        licenseNote: 'CMSIS-SVD register description (vendor-published)',
        part: part,
      ));
    } else if (part != null) {
      items.add(FetchItem(
        key: 'svd:$part',
        url: Uri.parse(
            'https://raw.githubusercontent.com/modm-io/cmsis-svd-stm32/$_svdRepoCommit/$family/${part.toUpperCase()}.svd'),
        kind: CorpusItemKind.svd,
        approxBytes: 512 * 1024,
        licenseNote: 'CMSIS-SVD register description (vendor-published)',
        part: part,
      ));
    } else {
      notes.add('Part unknown (family-level detection) — no SVD register '
          'map will be fetched. Set the exact part to include one.');
    }

    final pdfs = _partPdfs[part];
    if (pdfs != null) {
      for (final (key, url, kind) in pdfs) {
        items.add(FetchItem(
          key: key,
          url: Uri.parse(url),
          kind: kind,
          approxBytes: 8 * 1024 * 1024,
          licenseNote: 'ST document — local reference use only',
          part: part,
          optional: true,
        ));
      }
    } else {
      notes.add('No curated datasheet/reference-manual URL for '
          '${part ?? family} — place PDFs in the corpus drop_in/ folder '
          'to include them.');
    }

    return FetchPlan(
      corpusKey: chip.corpusKey!,
      chip: chip,
      items: items,
      notes: notes,
    );
  }
}
