import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import '../../core/app_paths.dart';

part 'artifact_database.g.dart';

/// Indexed firmware images, keyed by SHA-256 hash of the ELF file.
class FirmwareImages extends Table {
  TextColumn get elfHash => text()();
  TextColumn get fileName => text()();
  /// Raw e_machine field from the ELF header (see `Machine.fromValue`
  /// in callgraph-dart). Stored as an int so the column is independent
  /// of the enum's Dart-side name. Null for rows registered before
  /// schema v5 — backfilled lazily on the next `processElfFile`.
  IntColumn get machine => integer().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {elfHash};
}

/// Symbols belonging to a firmware image.
///
/// Records which functions exist per firmware (read from the ELF's call
/// graph at registration time). Used by the Hook DB symbol-picker and
/// for downstream verification — NOT by the artifacts table, which is
/// independently keyed.
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

/// Pool of available hook bodies. Hooks are symbol-independent — the
/// pool is the catalog's default templates plus however many user-
/// authored hooks the user has created, regardless of which firmware
/// or symbol they end up bound to.
///
/// Two flavors, distinguished by [origin]:
///
/// - **Template** (`origin = 'default'`) — a builder-emitted body
///   seeded by `ArtifactLibraryService.ensureDefaultTemplates`.
///   `name` is null (UI derives a label from the body); `architecture`
///   is stamped at seed time.
/// - **User-authored** (`origin = 'user'`) — a body the user created
///   via the Hook Database dialog. `name` and `architecture` are
///   both required.
///
/// The (symbol → artifact) mapping lives in `Emulator.hookOverrides`,
/// not here. That keeps the DB sized by the number of distinct *hooks*,
/// not by `symbols × hooks`.
class Artifacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get artifactType => text()();
  TextColumn get artifactData => text()();
  TextColumn get origin =>
      text().withDefault(const Constant('default'))();
  /// User-supplied label for `origin='user'` rows. Null for templates
  /// (the UI derives a label from the body via the same `_hookLabel`
  /// regexes the metadata sidebar uses).
  TextColumn get name => text().nullable()();
  /// `'ARM'` / `'x86_64'` / null = any. Stamped at seed time for
  /// templates; set by the user for user-authored hooks.
  TextColumn get architecture => text().nullable()();
  /// Null = a reusable hook that the synthesizer can offer for any
  /// symbol. Non-null = a replacement hook the user authored for one
  /// specific function (the synthesizer prefers it first for that
  /// symbol and skips it when iterating candidates for other
  /// symbols).
  TextColumn get targetSymbolName => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [FirmwareImages, Symbols, Artifacts])
class ArtifactDatabase extends _$ArtifactDatabase {
  /// Create the database at the default location.
  ///
  /// DB file: `~/.config/call_graph_viewer/artifact_library/artifacts.db`
  factory ArtifactDatabase() => ArtifactDatabase._internal(_openConnection());
  ArtifactDatabase._internal(super.e);

  /// Create with a custom executor (for testing).
  factory ArtifactDatabase.forTesting(QueryExecutor executor) =>
      ArtifactDatabase._internal(executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 3) {
            // Pre-v3 was destructive: v1 stored one row per
            // (symbol, hook), v2 added target_elf_hash /
            // target_symbol_name, v3 dropped them entirely in favor
            // of name + architecture. User authorized destructive at
            // the time — no data of consequence existed. The
            // recreated table is built from the CURRENT schema, so
            // it already contains every additive column below — the
            // `else if` chain ensures we don't double-add them.
            await m.deleteTable('artifacts');
            await m.createTable(artifacts);
          } else if (from < 4) {
            // Additive: reintroduce target_symbol_name (different
            // semantics from the v2 column — now it marks a
            // replacement hook authored for one specific function,
            // optional and orthogonal to origin).
            await m.addColumn(artifacts, artifacts.targetSymbolName);
          }
          if (from < 5) {
            // Additive: cache the ELF's e_machine value on the
            // firmware row so the UI doesn't re-parse on every
            // dialog open. Backfilled lazily by `processElfFile`.
            await m.addColumn(firmwareImages, firmwareImages.machine);
          }
        },
      );

  // =========================================================================
  // FIRMWARE IMAGE OPERATIONS
  // =========================================================================

  /// Look up a firmware image by its ELF hash.
  Future<FirmwareImage?> getFirmwareByHash(String elfHash) =>
      (select(firmwareImages)..where((t) => t.elfHash.equals(elfHash)))
          .getSingleOrNull();

  /// Register a new firmware image with its symbol list.
  ///
  /// Records firmware metadata + the symbol names from the call graph.
  /// Hooks are NOT seeded per-symbol — templates are inserted globally
  /// once (see [ensureTemplates]). [machine] is the raw `e_machine`
  /// integer from the ELF header (see callgraph-dart's `Machine`
  /// enum); pass null only if the value isn't available at
  /// registration time.
  Future<void> registerFirmware({
    required String elfHash,
    required String fileName,
    required List<String> symbolNames,
    int? machine,
  }) =>
      transaction(() async {
        await into(firmwareImages).insert(FirmwareImagesCompanion.insert(
          elfHash: elfHash,
          fileName: fileName,
          machine: Value(machine),
        ));
        for (final name in symbolNames) {
          await into(symbols).insert(SymbolsCompanion.insert(
            elfHash: elfHash,
            symbolName: name,
          ));
        }
      });

  /// Backfill the [machine] column for a previously-registered
  /// firmware row. Used by [ArtifactLibraryService.processElfFile]
  /// to fill in `machine` on pre-v5 rows the next time their ELF
  /// is opened.
  Future<int> updateFirmwareMachine({
    required String elfHash,
    required int machine,
  }) =>
      (update(firmwareImages)..where((t) => t.elfHash.equals(elfHash)))
          .write(FirmwareImagesCompanion(machine: Value(machine)));

  /// Get all symbols for a firmware image.
  Future<List<Symbol>> getSymbolsForFirmware(String elfHash) =>
      (select(symbols)..where((t) => t.elfHash.equals(elfHash))).get();

  /// Get a symbol by firmware hash and name.
  Future<Symbol?> getSymbol(String elfHash, String symbolName) =>
      (select(symbols)
            ..where((t) =>
                t.elfHash.equals(elfHash) & t.symbolName.equals(symbolName)))
          .getSingleOrNull();

  // =========================================================================
  // ARTIFACT OPERATIONS
  // =========================================================================

  /// Get a single artifact by its primary key ID.
  Future<Artifact?> getArtifactById(int id) =>
      (select(artifacts)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Get every template artifact (origin='default').
  Future<List<Artifact>> getTemplates() =>
      (select(artifacts)..where((t) => t.origin.equals('default'))).get();

  /// Get every hook artifact in the pool. Symbol-independent: there's
  /// no per-symbol filtering anymore — overrides decide which artifact
  /// applies to which symbol, not the DB.
  Future<List<Artifact>> getAllArtifacts() => (select(artifacts)
        ..orderBy([
          (t) => OrderingTerm.asc(t.origin), // 'default' before 'user'
          (t) => OrderingTerm.asc(t.id),
        ]))
      .get();

  /// Same shape as [getAllArtifacts]; the [elfHash] is ignored under
  /// the v3 schema (artifacts are symbol/firmware-independent). Kept
  /// for call-site compatibility with the Hook Database dialog and
  /// the synthesizer.
  Future<List<Artifact>> getArtifactsForSymbolByName(
    String elfHash,
    String symbolName,
  ) =>
      getAllArtifacts();

  /// Same shape as [getAllArtifacts]; the [elfHash] is ignored.
  Future<List<Artifact>> getAllArtifactsForFirmware(String elfHash) =>
      getAllArtifacts();

  /// Insert a new artifact. Templates pass `origin='default'` and
  /// typically leave `name` null (UI derives a label from the body).
  /// User hooks pass `origin='user'` and supply both [name] and
  /// [architecture]. Pass [targetSymbolName] when authoring a
  /// replacement hook for one specific function; leave null for
  /// reusable hooks.
  Future<int> addArtifact({
    required String artifactType,
    required String artifactData,
    required String origin,
    String? name,
    String? architecture,
    String? targetSymbolName,
  }) =>
      into(artifacts).insert(ArtifactsCompanion.insert(
        artifactType: artifactType,
        artifactData: artifactData,
        origin: Value(origin),
        name: Value(name),
        architecture: Value(architecture),
        targetSymbolName: Value(targetSymbolName),
      ));

  /// Delete an artifact by its primary key ID.
  Future<int> deleteArtifact(int id) =>
      (delete(artifacts)..where((t) => t.id.equals(id))).go();

  /// Update an artifact's code body in place. Preserves the artifact's
  /// primary-key id so any `hookOverrides` / `hookPreferences`
  /// references stay valid.
  Future<int> updateArtifactData({
    required int id,
    required String artifactData,
  }) =>
      (update(artifacts)..where((t) => t.id.equals(id)))
          .write(ArtifactsCompanion(artifactData: Value(artifactData)));
}

LazyDatabase _openConnection() => LazyDatabase(() async {
      final dbDir = AppPaths.artifactDbDir;
      await Directory(dbDir).create(recursive: true);
      final file = File('$dbDir/artifacts.db');
      return NativeDatabase.createInBackground(file);
    });
