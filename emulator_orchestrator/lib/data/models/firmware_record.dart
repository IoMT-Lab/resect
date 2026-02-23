/// Domain model representing a firmware image and its symbols in the artifact library.
///
/// This is a high-level view of the database record, combining the firmware
/// image metadata with its associated symbol names.
class FirmwareRecord {
  /// SHA-256 hash of the ELF file (primary key)
  final String elfHash;

  /// Original file name of the ELF
  final String fileName;

  /// When this firmware was first registered
  final DateTime createdAt;

  /// List of symbol (function) names in the firmware
  final List<String> symbolNames;

  const FirmwareRecord({
    required this.elfHash,
    required this.fileName,
    required this.createdAt,
    required this.symbolNames,
  });
}
