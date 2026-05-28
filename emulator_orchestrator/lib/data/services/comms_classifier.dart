import '../models/call_graph.dart';
import '../models/comms_assignment.dart';

/// Classifies the symbols in a [CallGraph] into Comms-tab buckets.
///
/// Two impls are envisioned: the [NamePatternCommsClassifier] (this file),
/// which uses case-insensitive substring matching on symbol names, and a
/// future engine-driven impl (e.g. instruction-pattern analysis). Both
/// produce the same shape — a map keyed by symbol name with the protocol
/// class and, when detectable, a read/write role.
///
/// Classifiers do NOT touch the [Emulator]; the orchestrator merges their
/// output with any persisted user reassignments. Symbols whose substring
/// doesn't match a known protocol are simply omitted from the returned map
/// (they don't appear in the Comms tab at all — not even as `unclassified`,
/// which is reserved for user-moved items).
// ignore: one_member_abstracts
abstract class CommsClassifier {
  Map<String, CommsAssignment> classify(CallGraph graph);
}

/// Substring-heuristic classifier — case-insensitive `contains` against the
/// symbol name. Catches most embedded SDKs without per-vendor pattern lists:
/// STM HAL/LL (`HAL_I2C_*`, `LL_I2C_*`), Nordic (`nrf_drv_i2c_*`,
/// `nrfx_i2c_*`), ESP-IDF (`i2c_master_*`), NXP (`LPI2C_*`), TI, Microchip,
/// Renesas, Arduino-style, generic snake_case. Some false positives — e.g.
/// `prepare_i2c_buffer` matches i2c — which the user moves to `unclassified`
/// or leaves alone.
class NamePatternCommsClassifier implements CommsClassifier {
  const NamePatternCommsClassifier();

  @override
  Map<String, CommsAssignment> classify(CallGraph graph) {
    final out = <String, CommsAssignment>{};
    for (final name in graph.symbols.keys) {
      final assignment = _classifyOne(name);
      if (assignment != null) {
        out[name] = assignment;
      }
    }
    return out;
  }

  /// Returns the classification for [name], or null if no protocol matches.
  /// Protocol detection runs in a fixed order: `usart` → uart (more specific
  /// than `uart`), `uart`, `i2c`, `spi`. Role is derived from the same name
  /// independently; null when the heuristic can't tell.
  CommsAssignment? _classifyOne(String name) {
    final lower = name.toLowerCase();
    CommsClass? protocol;
    // Check usart before uart so "usart" matches before its substring "uart"
    // does — same effect either way since both map to uart, but explicit.
    if (lower.contains('usart') || lower.contains('uart')) {
      protocol = CommsClass.uart;
    } else if (lower.contains('i2c')) {
      protocol = CommsClass.i2c;
    } else if (lower.contains('spi')) {
      protocol = CommsClass.spi;
    }
    if (protocol == null) return null;

    final role = _roleFor(lower);
    return CommsAssignment(protocol: protocol, role: role);
  }

  CommsRole? _roleFor(String lower) {
    // Read-flavored verbs first (most specific tokens like "receive" before
    // shorter ones that might appear elsewhere).
    const readTokens = ['receive', 'recv', 'read', 'get'];
    for (final t in readTokens) {
      if (lower.contains(t)) return CommsRole.read;
    }
    const writeTokens = ['transmit', 'write', 'send', 'put'];
    for (final t in writeTokens) {
      if (lower.contains(t)) return CommsRole.write;
    }
    return null;
  }
}
