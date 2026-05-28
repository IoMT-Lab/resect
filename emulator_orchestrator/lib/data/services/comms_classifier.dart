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

/// Token-aware case-insensitive heuristic classifier.
///
/// Matches the protocol literal as a *discrete token* in the symbol name
/// rather than as a substring anywhere. This avoids false positives like
/// `HAL_MspInit` (which contains "spi" only because of the `Msp`+`Init`
/// boundary) and `quartz` (which contains "uart").
///
/// Tokenization splits on:
///   - underscores
///   - lower→Upper CamelCase boundaries
///   - Upper→Upper-followed-by-lower transitions (so `LPSPIMaster` →
///     `LPSPI` + `Master`)
///
/// Protocol matches when any resulting token (after stripping trailing
/// digits) either:
///   - equals one of `i2c`/`spi`/`uart`/`usart` (case-insensitive); or
///   - is all-uppercase letters of length 4–7, ends with the protocol's
///     uppercase form, and the prefix is 1–3 uppercase letters (catches
///     NXP-style `LPI2C`/`LPSPI`/`LPUART`/`HSI2C`/`FSUART`).
///
/// Role matches when any token equals one of `receive`/`recv`/`read`/`get`
/// (read) or `transmit`/`write`/`send`/`put` (write).
///
/// Catches all common SDKs implicitly (STM HAL/LL, Nordic nrf_drv_*/nrfx_*,
/// ESP-IDF i2c_master_*, NXP LPI2C_*, TI, Microchip, Renesas, Arduino-style,
/// generic snake_case) without per-vendor pattern lists. Semantically
/// i2c-adjacent names like `prepare_i2c_buffer` still surface; the user
/// dismisses them into `unclassified` if they don't want them virtualized.
class NamePatternCommsClassifier implements CommsClassifier {
  const NamePatternCommsClassifier();

  /// Protocols keyed by their uppercase wire form, mapped to acceptable
  /// token literals (case-insensitive). uart accepts both `UART` and `USART`.
  static const Map<CommsClass, ({String suffix, Set<String> synonyms})>
      _protocols = {
    CommsClass.i2c: (suffix: 'I2C', synonyms: {'i2c'}),
    CommsClass.spi: (suffix: 'SPI', synonyms: {'spi'}),
    CommsClass.uart: (suffix: 'UART', synonyms: {'uart', 'usart'}),
  };

  static const _readTokens = {'receive', 'recv', 'read', 'get'};
  static const _writeTokens = {'transmit', 'write', 'send', 'put'};

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

  CommsAssignment? _classifyOne(String name) {
    final tokens = tokenize(name);
    final protocol = _matchProtocol(tokens);
    if (protocol == null) return null;
    final role = _matchRole(tokens);
    return CommsAssignment(protocol: protocol, role: role);
  }

  CommsClass? _matchProtocol(List<String> tokens) {
    // Prefer uart/usart over i2c/spi when both somehow appear; order is
    // arbitrary but deterministic. In practice a symbol won't carry tokens
    // for multiple distinct protocols.
    for (final entry in _protocols.entries) {
      for (final raw in tokens) {
        final stripped = _stripTrailingDigits(raw);
        if (stripped.isEmpty) continue;
        final lower = stripped.toLowerCase();
        if (entry.value.synonyms.contains(lower)) return entry.key;
        if (_matchesAcronymSuffix(stripped, entry.value.suffix)) {
          return entry.key;
        }
      }
    }
    return null;
  }

  CommsRole? _matchRole(List<String> tokens) {
    for (final raw in tokens) {
      final lower = _stripTrailingDigits(raw).toLowerCase();
      if (_readTokens.contains(lower)) return CommsRole.read;
      if (_writeTokens.contains(lower)) return CommsRole.write;
    }
    return null;
  }

  /// True when [token] contains only uppercase letters and digits (no
  /// lowercase), ends with [protocolSuffix], and the prefix is 1–3 chars
  /// of uppercase letters. The digit allowance is for embedded digits in
  /// protocol literals (e.g. the `2` in `I2C` / `LPI2C`); the prefix-must-
  /// be-letters rule keeps `1SPI` (or similar) from matching.
  static bool _matchesAcronymSuffix(String token, String protocolSuffix) {
    if (token.length <= protocolSuffix.length) return false;
    if (!token.endsWith(protocolSuffix)) return false;

    // Reject any lowercase letter anywhere in the token.
    for (var i = 0; i < token.length; i++) {
      final c = token.codeUnitAt(i);
      if (c >= 0x61 && c <= 0x7A) return false;
    }

    final prefixLen = token.length - protocolSuffix.length;
    if (prefixLen < 1 || prefixLen > 3) return false;

    // Prefix must be uppercase letters (not digits), to keep weird
    // digit-leading tokens from matching.
    for (var i = 0; i < prefixLen; i++) {
      final c = token.codeUnitAt(i);
      if (c < 0x41 || c > 0x5A) return false;
    }
    return true;
  }

  static String _stripTrailingDigits(String s) {
    var end = s.length;
    while (end > 0) {
      final c = s.codeUnitAt(end - 1);
      if (c < 0x30 || c > 0x39) break;
      end--;
    }
    return end == s.length ? s : s.substring(0, end);
  }
}

/// Splits [name] into tokens for comms classification. Public so tests can
/// pin the tokenization independently of the classifier's matching rules.
///
/// Splitting rules:
///   - boundary at every `_`
///   - boundary at every lower→Upper transition (`aB` → `a`, `B…`)
///   - boundary at every Upper→Upper-followed-by-lower transition
///     (`LPSPIMaster` → `LPSPI`, `Master`)
List<String> tokenize(String name) {
  final out = <String>[];
  for (final part in name.split('_')) {
    if (part.isEmpty) continue;
    out.addAll(_splitCamel(part));
  }
  return out;
}

List<String> _splitCamel(String s) {
  if (s.length <= 1) return [s];
  final out = <String>[];
  var start = 0;
  for (var i = 1; i < s.length; i++) {
    final prev = s.codeUnitAt(i - 1);
    final cur = s.codeUnitAt(i);
    final prevLower = prev >= 0x61 && prev <= 0x7A;
    final prevUpper = prev >= 0x41 && prev <= 0x5A;
    final curUpper = cur >= 0x41 && cur <= 0x5A;

    // lower→Upper: e.g. "aB" in "LcdSpi" splits between 'd' and 'S'.
    if (prevLower && curUpper) {
      out.add(s.substring(start, i));
      start = i;
      continue;
    }
    // Upper→Upper-followed-by-lower: e.g. in "LPSPIMaster", at position 5
    // ('I' then 'M' then 'a') split between 'I' and 'M' so "LPSPI" stays
    // intact and "Master" becomes its own token.
    if (prevUpper && curUpper && i + 1 < s.length) {
      final next = s.codeUnitAt(i + 1);
      final nextLower = next >= 0x61 && next <= 0x7A;
      if (nextLower) {
        out.add(s.substring(start, i));
        start = i;
      }
    }
  }
  out.add(s.substring(start));
  return out;
}
