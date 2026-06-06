import 'hook_catalog.dart';

/// Marker used by the Hook DB dialog to detect "starter template
/// already at the top of the buffer." Must stay byte-identical to
/// the first line emitted by [starterTemplate].
const String starterTemplatePrefix =
    '# This is a "hook" — Python that replaces one of your firmware';

/// Returns a working starter hook body for the New Hook flow,
/// targeted at users who haven't written a hook before. The
/// functional bytes come from the catalog's `returnHook(0)` (same
/// code path the synthesizer trusts); we wrap them with a
/// plain-English header explaining what a hook is and an inline
/// marker on the editable line. No per-arch knowledge here — the
/// catalog stays the single source for ABI.
String starterTemplate() {
  final body = HookCatalog.system()
      .build('return', {'value': 0})
      .code
      .replaceFirst(
        'setReturnValue(cpu, 0)',
        'setReturnValue(cpu, 0)  '
        '# ← edit the 0 to change what the function returns',
      );
  return '$_header\n$body';
}

const _header = '''# This is a "hook" — Python that replaces one of your firmware's
# functions. When the firmware calls that function, this code
# runs instead, and Renode pretends the function returned
# whatever this code says.
#
# This template makes the function always return 0. To change
# the return value, edit the number on the last line.
#
# Want a different shape? Click any [DEFAULT] row in the left
# pane to see other patterns — for example, hooks that remember
# a value across calls, or count how many times a function is
# called. Fork any default via "Save As New" to start from it.''';
