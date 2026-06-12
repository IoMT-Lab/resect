import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

import '../../../data/models/call_graph.dart';
import '../../../data/models/symbol.dart';
import '../../../data/services/call_graph_service.dart';
import '../../../data/services/signatures_service.dart';
import '../call_graph_source.dart';

/// [CallGraphSource] backed by Ghidra headless analysis (via
/// `signatures-dart` and the `ghidra_call_graphs` cache table).
///
/// Resolution order:
///   1. **Cache hit** — `CallGraphService.callGraphFor(elfHash)` has
///      a row; we deserialise and return it without subprocess cost.
///   2. **Cache miss** — kick off `SignaturesService.extractFor` and
///      wait for it to finish. The extraction populates both the
///      signatures table AND the call-graph table in one Ghidra
///      pass; we read back the call graph after.
///   3. **Extraction failure** — propagate the underlying exception
///      so the engine layer can fall back to the objdump-based
///      `DartCallGraphSource`.
///
/// Indirect-call edges Ghidra couldn't resolve to a concrete
/// function appear in the resect `Symbol.calledSymbols` map with
/// names of the form `<indirect:0xADDR>`. Downstream consumers
/// (Call Graph tab, fidelity calculator) treat them as ordinary
/// edges; UI may filter them by default in a future slice.
class GhidraCallGraphSource implements CallGraphSource {
  GhidraCallGraphSource({
    required this.signaturesService,
    required this.callGraphService,
  });

  final SignaturesService signaturesService;
  final CallGraphService callGraphService;

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
    final elfHash = await _hashFile(File(elfPath));
    var cached = await callGraphService.callGraphFor(elfHash);
    if (cached == null) {
      // No cache row. Run extraction (this also populates the
      // signatures table). Drain the progress stream — the engine
      // layer doesn't surface it; SignaturesService callers that
      // want progress invoke extractFor directly.
      await for (final _ in signaturesService.extractFor(elfPath)) {
        // intentionally empty
      }
      cached = await callGraphService.callGraphFor(elfHash);
      if (cached == null) {
        throw StateError(
          'Ghidra extraction completed but no call-graph row was '
          'written for $elfHash. Check the daemon log.',
        );
      }
    }
    // Map the signatures-dart CallGraphNode shape into resect's
    // Symbol shape. Resect drops `address` (the model is
    // address-agnostic post-symbol-resolution); we keep
    // `num_instructions` and the edges map.
    final symbols = <String, Symbol>{
      for (final entry in cached.entries)
        entry.key: Symbol(
          name: entry.key,
          numInstructions: entry.value.numInstructions,
          calledSymbols: Map<String, int>.from(entry.value.calls),
        ),
    };
    return CallGraph(elfPath: elfPath, symbols: symbols);
  }

  Future<String> _hashFile(File f) async =>
      sha256.convert(await f.readAsBytes()).toString();
}
