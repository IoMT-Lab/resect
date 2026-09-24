import 'package:xml/xml.dart';

/// One distilled peripheral: a compact, embeddable text block of its
/// register map. These are the highest-value corpus chunks for hook
/// synthesis — base address, register offsets/reset values, and field
/// bit ranges are exactly what a hook standing in for a peripheral
/// needs to return plausible values.
class SvdPeripheralChunk {
  const SvdPeripheralChunk({required this.name, required this.text});
  final String name;
  final String text;
}

/// Parse a CMSIS-SVD file into one text chunk per peripheral.
///
/// Handles `derivedFrom` (a peripheral inheriting another's registers)
/// and register-array `dim`. Uses `package:xml` — SVDs nest fields
/// several levels deep and a regex parse is a correctness trap.
class SvdDistiller {
  const SvdDistiller();

  List<SvdPeripheralChunk> distill(String svdXml, {required String part}) {
    final doc = XmlDocument.parse(svdXml);
    final device = doc.rootElement;
    final deviceName = _text(device, 'name') ?? part;

    // Index peripherals by name for derivedFrom resolution.
    final periphs = device.findAllElements('peripheral').toList();
    final byName = <String, XmlElement>{
      for (final p in periphs)
        if (_text(p, 'name') != null) _text(p, 'name')!: p,
    };

    final chunks = <SvdPeripheralChunk>[];
    for (final p in periphs) {
      final name = _text(p, 'name');
      if (name == null) continue;
      final base = _text(p, 'baseAddress') ?? '';
      final desc = _text(p, 'description');

      // Registers come from this peripheral, or the one it derives from.
      var regHost = p;
      final derived = p.getAttribute('derivedFrom');
      if (p.findElements('registers').isEmpty &&
          derived != null &&
          byName.containsKey(derived)) {
        regHost = byName[derived]!;
      }

      final buf = StringBuffer()
        ..writeln('Peripheral: $name'
            '${derived != null ? ' (derived from $derived)' : ''} '
            '@ $base  [$deviceName]');
      if (desc != null && desc != name) buf.writeln('  $desc');

      for (final reg in regHost.findAllElements('register')) {
        final rName = _text(reg, 'name') ?? '?';
        final offset = _text(reg, 'addressOffset') ?? '';
        final reset = _text(reg, 'resetValue');
        final access = _text(reg, 'access');
        buf.write('  $rName  offset $offset');
        if (reset != null) buf.write('  reset $reset');
        if (access != null) buf.write('  ($access)');
        buf.writeln();
        final fields = reg.findAllElements('field').toList();
        if (fields.isNotEmpty) {
          final parts = <String>[];
          for (final f in fields.take(32)) {
            final fName = _text(f, 'name') ?? '?';
            final bit = _bitRange(f);
            parts.add(bit == null ? fName : '$fName$bit');
          }
          buf.writeln('    fields: ${parts.join(', ')}');
        }
      }
      chunks.add(SvdPeripheralChunk(name: name, text: buf.toString().trim()));
    }
    return chunks;
  }

  static String? _text(XmlElement e, String tag) {
    final els = e.findElements(tag);
    if (els.isEmpty) return null;
    final t = els.first.innerText.trim();
    return t.isEmpty ? null : t;
  }

  /// `[hi:lo]` from either bitRange, or offset+width, or lsb/msb.
  static String? _bitRange(XmlElement field) {
    final range = _text(field, 'bitRange');
    if (range != null) return range; // already like [7:0]
    final offset = _text(field, 'bitOffset');
    final width = _text(field, 'bitWidth');
    if (offset != null && width != null) {
      final o = int.tryParse(offset);
      final w = int.tryParse(width);
      if (o != null && w != null) {
        return w == 1 ? '[$o]' : '[${o + w - 1}:$o]';
      }
    }
    final lsb = _text(field, 'lsb');
    final msb = _text(field, 'msb');
    if (lsb != null && msb != null) return '[$msb:$lsb]';
    return null;
  }
}
