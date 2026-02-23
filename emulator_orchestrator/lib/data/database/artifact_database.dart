import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import '../../core/app_paths.dart';

part 'artifact_database.g.dart';

/// Indexed firmware images, keyed by SHA-256 hash of the ELF file.
class FirmwareImages extends Table {
  TextColumn get elfHash => text()();
  TextColumn get fileName => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {elfHash};
}

/// Symbols belonging to a firmware image.
///
/// Each symbol corresponds to a function in the ELF file. These records
/// serve as anchors for per-symbol artifacts (hooks, annotations, etc).
class Symbols extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get elfHash => text().references(FirmwareImages, #elfHash)();
  TextColumn get symbolName => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {elfHash, symbolName},
      ];
}

/// Artifacts associated with a symbol.
///
/// Initially this will store Renode hooks, but the schema supports
/// any artifact type (hooks, annotations, breakpoints, etc).
class Artifacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get symbolId => integer().references(Symbols, #id)();
  TextColumn get artifactType => text()();
  TextColumn get artifactData => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [FirmwareImages, Symbols, Artifacts])
class ArtifactDatabase extends _$ArtifactDatabase {
  ArtifactDatabase._internal(super.e);

  /// Create the database at the default location.
  ///
  /// DB file: `~/.config/call_graph_viewer/artifact_library/artifacts.db`
  factory ArtifactDatabase() {
    return ArtifactDatabase._internal(_openConnection());
  }

  /// Create with a custom executor (for testing).
  factory ArtifactDatabase.forTesting(QueryExecutor executor) {
    return ArtifactDatabase._internal(executor);
  }

  @override
  int get schemaVersion => 1;

  // =========================================================================
  // FIRMWARE IMAGE OPERATIONS
  // =========================================================================

  /// Look up a firmware image by its ELF hash.
  Future<FirmwareImage?> getFirmwareByHash(String elfHash) {
    return (select(firmwareImages)..where((t) => t.elfHash.equals(elfHash)))
        .getSingleOrNull();
  }

  /// Register a new firmware image with its symbols and default hooks.
  ///
  /// Inserts the firmware record, all symbol records, and default hook
  /// artifacts in a single transaction to ensure atomicity.
  Future<void> registerFirmware({
    required String elfHash,
    required String fileName,
    required List<String> symbolNames,
    required String return0HookCode,
    required String return1HookCode,
  }) {
    return transaction(() async {
      await into(firmwareImages).insert(FirmwareImagesCompanion.insert(
        elfHash: elfHash,
        fileName: fileName,
      ));

      for (final name in symbolNames) {
        final symbolId = await into(symbols).insert(SymbolsCompanion.insert(
          elfHash: elfHash,
          symbolName: name,
        ));

        await into(artifacts).insert(ArtifactsCompanion.insert(
          symbolId: symbolId,
          artifactType: 'renode_hook',
          artifactData: return0HookCode,
        ));
        await into(artifacts).insert(ArtifactsCompanion.insert(
          symbolId: symbolId,
          artifactType: 'renode_hook',
          artifactData: return1HookCode,
        ));
      }
    });
  }

  /// Get all symbols for a firmware image.
  Future<List<Symbol>> getSymbolsForFirmware(String elfHash) {
    return (select(symbols)..where((t) => t.elfHash.equals(elfHash))).get();
  }

  /// Get a symbol by firmware hash and name.
  Future<Symbol?> getSymbol(String elfHash, String symbolName) {
    return (select(symbols)
          ..where(
              (t) => t.elfHash.equals(elfHash) & t.symbolName.equals(symbolName)))
        .getSingleOrNull();
  }

  // =========================================================================
  // ARTIFACT OPERATIONS
  // =========================================================================

  /// Get a single artifact by its primary key ID.
  Future<Artifact?> getArtifactById(int id) {
    return (select(artifacts)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Get all artifacts for a symbol.
  Future<List<Artifact>> getArtifactsForSymbol(int symbolId) {
    return (select(artifacts)..where((t) => t.symbolId.equals(symbolId))).get();
  }

  /// Get all artifacts for a symbol identified by firmware hash and symbol name.
  Future<List<Artifact>> getArtifactsForSymbolByName(String elfHash, String symbolName) async {
    final symbol = await getSymbol(elfHash, symbolName);
    if (symbol == null) return [];
    return getArtifactsForSymbol(symbol.id);
  }

  /// Add an artifact to a symbol.
  Future<int> addArtifact({
    required int symbolId,
    required String artifactType,
    required String artifactData,
  }) {
    return into(artifacts).insert(ArtifactsCompanion.insert(
      symbolId: symbolId,
      artifactType: artifactType,
      artifactData: artifactData,
    ));
  }

  /// Delete an artifact by its primary key ID.
  Future<int> deleteArtifact(int id) {
    return (delete(artifacts)..where((t) => t.id.equals(id))).go();
  }

  /// Get all artifacts for a firmware image, joined with symbol names.
  ///
  /// Returns a flat list of (symbolName, artifact) pairs ordered by
  /// symbol name then artifact ID. Single SQL round-trip.
  Future<List<({String symbolName, Artifact artifact})>>
      getAllArtifactsForFirmware(String elfHash) async {
    final query = select(artifacts).join([
      innerJoin(symbols, symbols.id.equalsExp(artifacts.symbolId)),
    ])
      ..where(symbols.elfHash.equals(elfHash))
      ..orderBy([
        OrderingTerm.asc(symbols.symbolName),
        OrderingTerm.asc(artifacts.id),
      ]);

    final rows = await query.get();
    return rows.map((row) {
      final symbol = row.readTable(symbols);
      final artifact = row.readTable(artifacts);
      return (symbolName: symbol.symbolName, artifact: artifact);
    }).toList();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbDir = AppPaths.artifactDbDir;

    // Ensure directory exists
    await Directory(dbDir).create(recursive: true);

    final file = File('$dbDir/artifacts.db');
    return NativeDatabase.createInBackground(file);
  });
}
