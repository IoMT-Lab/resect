import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/services/artifact_library_service.dart';
import 'package:emulator_orchestrator/data/services/hook_catalog.dart';
import 'package:test/test.dart';

/// Verifies the 2026-06-17 dedup migration: when a DB seeded with
/// pre-A2 `RegisterValue.Create(N, 64)` legacy return bodies meets
/// the manual "Reseed defaults" path, `reseedDefaults()` deletes
/// the legacy rows AND returns a remap pointing existing
/// `hookOverrides[sym] = legacyId` references at the surviving
/// catalog return ids — not null.
///
/// The bug class this guards: pre-fix, `_matchCanonical` resolved
/// `Create(0,`-shaped obsolete bodies to a target body that we
/// just removed from the seed set, so the remap returned null and
/// any project override at the legacy id would orphan after a
/// Reseed click.
void main() {
  group('reseedDefaults — legacy return remap', () {
    late ArtifactDatabase db;
    late ArtifactLibraryService service;

    setUp(() {
      db = ArtifactDatabase.forTesting(NativeDatabase.memory());
      service = ArtifactLibraryService(db);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'legacy Create(0, 64) body remaps to catalog return-0 id (not null)',
        () async {
      // Insert a legacy-shaped row first, then ensure the new
      // catalog defaults are present. ensureDefaultTemplates is
      // idempotent so it only adds the catalog returns alongside.
      final legacyId = await db.addArtifact(
        artifactType: 'renode_hook',
        artifactData: '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(0, 64))
cpu.PC = cpu.LR
''',
        origin: 'default',
        architecture: 'ARM',
      );
      await service.ensureDefaultTemplates();

      // Look up the catalog return-0 row's id so we can assert
      // remap[legacyId] points there.
      final catalog = HookCatalog.system();
      final catalogReturn0Body =
          catalog.build('return', const {'value': 0}).code;
      final catalogReturn0Id = (await db.getAllArtifacts())
          .firstWhere((a) => a.artifactData == catalogReturn0Body)
          .id;

      final remap = await service.reseedDefaults();

      // The legacy row should have been deleted.
      final remaining = await db.getAllArtifacts();
      expect(remaining.where((a) => a.id == legacyId), isEmpty,
          reason: 'legacy row $legacyId should have been deleted');
      // And its id should remap to the catalog return-0 id, NOT null.
      expect(remap[legacyId], isNotNull,
          reason: 'legacy id must remap, not orphan');
      expect(remap[legacyId], equals(catalogReturn0Id));
    });

    test(
        'legacy Create(1, 64) body remaps to catalog return-1 id (not null)',
        () async {
      final legacyId = await db.addArtifact(
        artifactType: 'renode_hook',
        artifactData: '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(1, 64))
cpu.PC = cpu.LR
''',
        origin: 'default',
        architecture: 'ARM',
      );
      await service.ensureDefaultTemplates();

      final catalog = HookCatalog.system();
      final catalogReturn1Body =
          catalog.build('return', const {'value': 1}).code;
      final catalogReturn1Id = (await db.getAllArtifacts())
          .firstWhere((a) => a.artifactData == catalogReturn1Body)
          .id;

      final remap = await service.reseedDefaults();

      final remaining = await db.getAllArtifacts();
      expect(remaining.where((a) => a.id == legacyId), isEmpty);
      expect(remap[legacyId], equals(catalogReturn1Id));
    });

    test(
        'ensureDefaultTemplates on a fresh DB seeds 8 rows, not 10 '
        '(the legacy returns are no longer in the seed set)',
        () async {
      await service.ensureDefaultTemplates();
      final defaults =
          (await db.getAllArtifacts()).where((a) => a.origin == 'default');
      expect(defaults, hasLength(8),
          reason:
              '8 catalog templates: 2 return + 2 read + 2 write + 2 increment');
    });
  });
}
