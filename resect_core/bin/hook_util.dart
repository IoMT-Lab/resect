import 'dart:io';
import 'package:path/path.dart';

import 'package:renode/renode.dart';

Map<String, String> importCache = {};
void loadImports({String importDir = 'bin/python'}) {
  final dir = Directory(importDir);
  final files = dir.listSync().whereType<File>();
  for (final file in files) {
    final name = basenameWithoutExtension(file.path);
    importCache[name] = file.readAsStringSync();
  }
}

Hook createHook(String code, {String? scope, List<String>? imports}) {
  final importCode = (imports ?? []).map((name) => importCache[name] ?? '').join('\n');
  return Hook('$importCode\n$code', scope: scope);
}
