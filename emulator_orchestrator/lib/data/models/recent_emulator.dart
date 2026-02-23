/// Represents a recently opened emulator in the recent emulators list.
///
/// This lightweight model is used for the File → Recent Emulators menu
/// and stored in app data directory for persistence.
class RecentEmulator {
  /// Absolute path to the .emu file
  final String path;

  /// User-friendly emulator name
  final String name;

  /// When this emulator was last opened
  final DateTime lastOpened;

  const RecentEmulator({
    required this.path,
    required this.name,
    required this.lastOpened,
  });

  /// Load from JSON
  factory RecentEmulator.fromJson(Map<String, dynamic> json) {
    return RecentEmulator(
      path: json['path'] as String,
      name: json['name'] as String,
      lastOpened: DateTime.parse(json['last_opened'] as String),
    );
  }

  /// Convert to JSON for saving
  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'name': name,
      'last_opened': lastOpened.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RecentEmulator && other.path == path;
  }

  @override
  int get hashCode => path.hashCode;
}
