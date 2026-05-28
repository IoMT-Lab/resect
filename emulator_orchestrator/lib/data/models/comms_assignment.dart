/// Communication-bus classification for a single symbol in the call graph.
///
/// Resect's Comms tab groups firmware functions by the bus protocol they
/// drive (i2c / spi / uart), plus a catch-all `unclassified` bucket for
/// protocol-matched-but-ambiguous symbols and for user-moved items. The
/// `protocol` field determines the Renode `scope` used when the hook is
/// applied (one scope per protocol — see the design intent in the migration
/// plan). `role` is nullable because the unclassified bucket and ambiguous
/// matches have no resolved role yet.
class CommsAssignment {
  final CommsClass protocol;
  final CommsRole? role;

  const CommsAssignment({required this.protocol, this.role});

  CommsAssignment copyWith({CommsClass? protocol, CommsRole? role, bool clearRole = false}) =>
      CommsAssignment(
        protocol: protocol ?? this.protocol,
        role: clearRole ? null : (role ?? this.role),
      );

  Map<String, dynamic> toJson() => {
        'protocol': protocol.name,
        if (role != null) 'role': role!.name,
      };

  factory CommsAssignment.fromJson(Map<String, dynamic> json) => CommsAssignment(
        protocol: CommsClass.values.byName(json['protocol'] as String),
        role: json['role'] != null
            ? CommsRole.values.byName(json['role'] as String)
            : null,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CommsAssignment && other.protocol == protocol && other.role == role);

  @override
  int get hashCode => Object.hash(protocol, role);

  @override
  String toString() => 'CommsAssignment(protocol: ${protocol.name}, role: ${role?.name})';
}

/// The four classification buckets surfaced in the Comms tab.
///
/// `i2c`/`spi`/`uart` are real comms protocols, each backed by a single
/// Renode scope ('i2c'/'spi'/'uart'). `unclassified` is a catch-all for
/// symbols whose protocol-substring match was ambiguous or that the user
/// moved here — it has no Python interface and can't be virtualized.
enum CommsClass { i2c, spi, uart, unclassified }

/// Direction of a comms call — read (peripheral → firmware) or write
/// (firmware → peripheral). Roles are derived from the symbol name where
/// possible; null role means the heuristic couldn't tell.
enum CommsRole { read, write }
