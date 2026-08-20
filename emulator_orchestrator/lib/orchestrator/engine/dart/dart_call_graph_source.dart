import 'dart:async';

import 'package:resect_callgraph/resect_callgraph.dart' as cg;

import '../../../config/env_config.dart';
import '../../../data/models/call_graph.dart';
import '../../../data/models/symbol.dart';
import '../../../services/analysis/call_graph_guard.dart';
import '../call_graph_source.dart';

/// [CallGraphSource] backed by callgraph-dart's in-process `objdump`-based
/// extraction. No server/transport — `connect()` is a formality.
class DartCallGraphSource implements CallGraphSource {
  final _statusController = StreamController<bool>.broadcast();
  var _connected = false;

  @override
  Future<bool> connect() async {
    _connected = true;
    _statusController.add(true);
    return true;
  }

  @override
  void disconnect() {
    _connected = false;
    _statusController.add(false);
  }

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionStatus => _statusController.stream;

  @override
  Future<CallGraph> getCallGraph(String elfPath) async {
    // Apply configured objdump paths (resect.config) if present; otherwise
    // callgraph-dart falls back to its env-var / PATH defaults.
    final cfg = EnvConfig.load();
    final arm = cfg.get('ARM_OBJDUMP');
    if (arm != null) cg.armObjdump = arm;
    final x86 = cfg.get('X86_OBJDUMP');
    if (x86 != null) cg.x86Objdump = x86;

    // Stamp the graph with its source ELF's hash BEFORE extracting, so a
    // file replaced mid-extraction can't get a stamp for bytes the graph
    // wasn't built from.
    final elfHash = await sha256OfFile(elfPath);
    final extracted = await cg.extractCallgraph(elfPath);
    final symbols = <String, Symbol>{};
    extracted.symbols.forEach((name, s) {
      symbols[name] = Symbol(
        name: name,
        // callgraph-dart exposes byte size, not an instruction count; use it as
        // a proxy until per-function instruction counting is added.
        numInstructions: s.size,
        calledSymbols: Map<String, int>.from(s.calledFunctions),
      );
    });
    return CallGraph(elfPath: elfPath, symbols: symbols, elfHash: elfHash);
  }
}
