import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/services/hooks/hook_classifier.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/rag/rag_index.dart';
import 'package:resect_signatures/resect_signatures.dart';
import 'package:test/test.dart';

// Integration test for `LlmHookGenerator.pinnedDataTypeHits` — the
// lookup that pins a `data_type` chunk for each typed pointer
// parameter so the LLM has the struct size + layout it needs to
// emit `pointer.writeData(cpu, ptr, [0] * N)` instead of falling
// back to the no-op.

final _kElfHash = 'a' * 64;

Future<ArtifactDatabase> _seedDb({
  required List<({String typeName, String definition})> dataTypes,
}) async {
  final db = ArtifactDatabase.forTesting(NativeDatabase.memory());
  await db.into(db.firmwareImages).insert(
        FirmwareImagesCompanion.insert(
          elfHash: _kElfHash,
          fileName: 'test.elf',
        ),
      );
  for (final dt in dataTypes) {
    await db.into(db.ghidraDataTypes).insert(
          GhidraDataTypesCompanion.insert(
            elfHash: _kElfHash,
            typeName: dt.typeName,
            definitionText: dt.definition,
          ),
        );
  }
  return db;
}

LlmHookGenerator _makeGenerator(ArtifactDatabase? db) {
  // RagIndex + LlmClient aren't touched by `pinnedDataTypeHits`;
  // construct cheap stubs so the generator instantiates.
  final client = LlmClient(host: 'localhost:11434', model: 'unused');
  final index = RagIndex(
    projectDir: '/tmp/unused-rag-${DateTime.now().microsecondsSinceEpoch}',
    client: client,
  );
  return LlmHookGenerator(
    index: index,
    client: client,
    artifactDb: db,
    classifier: const HookClassifier(),
  );
}

FunctionSignature _sig({
  required String name,
  required List<({String name, String type})> params,
}) =>
    FunctionSignature.fromJson(name, {
      'return_type': 'int',
      'calling_convention': '__stdcall',
      'parameters': [
        for (var i = 0; i < params.length; i++)
          {
            'name': params[i].name,
            'type': params[i].type,
            'storage': 'r$i',
          },
      ],
    });

void main() {
  group('pinnedDataTypeHits', () {
    test('matches a typedef by /DWARF/.../<basename> suffix', () async {
      final db = await _seedDb(dataTypes: [
        (
          typeName: '/DWARF/nvm_db.c/NVMDB_info',
          definition: 'struct NVMDB_info { /* size=20 */ };',
        ),
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'info', type: 'NVMDB_info *'),
        ]),
      );
      expect(hits, hasLength(1));
      expect(hits.single.sourceKind, 'data_type');
      expect(hits.single.sourceId, '/DWARF/nvm_db.c/NVMDB_info');
      expect(hits.single.text, contains('NVMDB_info'));
      await db.close();
    });

    test('matches a type stored without a path prefix (exact equality)',
        () async {
      final db = await _seedDb(dataTypes: [
        (typeName: 'BareStruct', definition: 'struct BareStruct {};'),
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'p', type: 'BareStruct *'),
        ]),
      );
      expect(hits, hasLength(1));
      expect(hits.single.sourceId, 'BareStruct');
      await db.close();
    });

    test('multiple typed pointer parameters yield multiple pinned hits',
        () async {
      final db = await _seedDb(dataTypes: [
        (typeName: '/DWARF/a.c/Alpha', definition: 'struct Alpha {};'),
        (typeName: '/DWARF/b.c/Beta', definition: 'struct Beta {};'),
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'a', type: 'Alpha *'),
          (name: 'b', type: 'Beta *'),
        ]),
      );
      expect(hits, hasLength(2));
      final ids = hits.map((h) => h.sourceId).toSet();
      expect(ids, {'/DWARF/a.c/Alpha', '/DWARF/b.c/Beta'});
      await db.close();
    });

    test('synthetic IDs are unique negatives at or below -2', () async {
      final db = await _seedDb(dataTypes: [
        (typeName: '/DWARF/a.c/Alpha', definition: 'struct Alpha {};'),
        (typeName: '/DWARF/b.c/Beta', definition: 'struct Beta {};'),
        (typeName: '/DWARF/c.c/Gamma', definition: 'struct Gamma {};'),
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'a', type: 'Alpha *'),
          (name: 'b', type: 'Beta *'),
          (name: 'c', type: 'Gamma *'),
        ]),
      );
      final idSet = hits.map((h) => h.id).toSet();
      expect(idSet, hasLength(3), reason: 'IDs should be unique');
      for (final id in idSet) {
        expect(id, lessThanOrEqualTo(-2),
            reason: 'IDs should not collide with the pinned-decomp ID (-1) '
                'or with any real RAG row ID (positive)');
      }
      await db.close();
    });

    test('missing types are silently skipped', () async {
      final db = await _seedDb(dataTypes: [
        (typeName: '/DWARF/a.c/Alpha', definition: 'struct Alpha {};'),
        // Beta is NOT seeded — should not produce a hit, must not throw.
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'a', type: 'Alpha *'),
          (name: 'b', type: 'Beta *'),
        ]),
      );
      expect(hits, hasLength(1));
      expect(hits.single.sourceId, '/DWARF/a.c/Alpha');
      await db.close();
    });

    test('primitive pointer params do not request a data_type lookup',
        () async {
      final db = await _seedDb(dataTypes: [
        // Even if a uint32_t typedef row exists in DWARF, we
        // shouldn't surface it — the LLM doesn't need it.
        (
          typeName: '/DWARF/_stdint.h/uint32_t',
          definition: 'typedef unsigned int uint32_t;',
        ),
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'buf', type: 'uint32_t *'),
        ]),
      );
      expect(hits, isEmpty);
      await db.close();
    });

    test('signature == null returns empty list', () async {
      final db = await _seedDb(dataTypes: const []);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: null,
      );
      expect(hits, isEmpty);
      await db.close();
    });

    test('artifactDb == null returns empty list', () async {
      final gen = _makeGenerator(null);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'p', type: 'NVMDB_info *'),
        ]),
      );
      expect(hits, isEmpty);
    });

    test('elfHash == null returns empty list', () async {
      final db = await _seedDb(dataTypes: const []);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: null,
        signature: _sig(name: 'fn', params: [
          (name: 'p', type: 'NVMDB_info *'),
        ]),
      );
      expect(hits, isEmpty);
      await db.close();
    });

    test('parameters with no pointer return no hits', () async {
      final db = await _seedDb(dataTypes: [
        (typeName: '/DWARF/x/Foo', definition: 'struct Foo {};'),
      ]);
      final gen = _makeGenerator(db);
      final hits = await gen.pinnedDataTypeHits(
        elfHash: _kElfHash,
        signature: _sig(name: 'fn', params: [
          (name: 'x', type: 'Foo'), // value, not pointer
          (name: 'y', type: 'int'),
        ]),
      );
      expect(hits, isEmpty);
      await db.close();
    });
  });
}
