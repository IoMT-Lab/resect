import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:signatures/signatures.dart' show DataSymbol, FunctionSignature;

import '../database/artifact_database.dart';
import '../models/hook_binding.dart';
import 'hook_classifier.dart';

/// Bulk-classifier pass that produces per-symbol [HookBinding]s for
/// every function in a firmware where the [HookClassifier] fires.
///
/// Conceptually this is the project-side half of Stage 1: the
/// classifier rules are deterministic on (signature, decomp,
/// data-symbols), so the *result* is firmware-wide truth — but the
/// **binding** that records the result is a per-project overlay (the
/// user can curate or override it without touching other projects on
/// the same firmware). This service runs once at project open over
/// the firmware's extracted Ghidra tables and returns a
/// `Map<String, HookBinding>` ready to merge into
/// `Emulator.hookBindings`.
///
/// Magnitudes follow the radiant-inventing-dream plan §2.1:
///
///   - `rule-1-empty-or-void-return` / `rule-2-return-literal` → **0.25**
///     (the classifier matched but the body chosen is a generic catalog
///     template — could be coincidence-tolerant).
///   - All other rules (`rule-3` through `rule-7`) → **0.5** (specialized
///     pattern — not coincidence-matchable).
///
/// Find-or-create: when the classifier's output body already exists as
/// an artifact (typically a default-origin catalog template) the
/// binding reuses that artifact id. Only when no match exists is a new
/// Replacement artifact inserted (`origin='user'`,
/// `targetSymbolName=<symbol>`, `intrinsicScore=0.5`).
class HookBindingSeeder {
  HookBindingSeeder({
    required ArtifactDatabase artifactDb,
    HookClassifier classifier = const HookClassifier(),
  })  : _db = artifactDb,
        _classifier = classifier;

  final ArtifactDatabase _db;
  final HookClassifier _classifier;

  /// Classify every function in [elfHash] that has both a signature
  /// and a non-empty decompilation, and return the resulting bindings.
  ///
  /// Symbols listed in [skipSymbols] are not classified — typically
  /// the symbols a project already has bindings for, so existing
  /// user/back-fill choices are preserved. Pass an empty set to
  /// classify every eligible function.
  ///
  /// Returns a fresh map of `symbol -> HookBinding`; the caller is
  /// responsible for merging it into the project's `hookBindings`
  /// (overlays write-wins or skip-existing per the caller's policy).
  Future<Map<String, HookBinding>> seedBindingsForElf({
    required String elfHash,
    Set<String> skipSymbols = const {},
  }) async {
    final decomps = await _db.decompilationsFor(elfHash);
    if (decomps.isEmpty) return const {};

    // Build the data-symbols map once per elfHash — it's the same
    // input for every function's classification.
    final dsRows = await _db.dataSymbolsFor(elfHash);
    final dataSymbols = <String, DataSymbol>{
      for (final r in dsRows)
        r.symbolName: DataSymbol(
          name: r.symbolName,
          address: r.address,
          type: r.typeName,
          size: r.size,
        ),
    };

    final now = DateTime.now();
    final bindings = <String, HookBinding>{};
    var classified = 0;
    var skipped = 0;
    var noSignature = 0;
    var emptyDecomp = 0;
    var newArtifacts = 0;

    for (final d in decomps) {
      final symbol = d.functionName;
      if (skipSymbols.contains(symbol)) {
        skipped++;
        continue;
      }
      if (d.sourceText.trim().isEmpty) {
        emptyDecomp++;
        continue;
      }

      final sigRow = await (_db.select(_db.signatures)
            ..where((t) =>
                t.elfHash.equals(elfHash) & t.symbolName.equals(symbol)))
          .getSingleOrNull();
      if (sigRow == null) {
        noSignature++;
        continue;
      }
      final FunctionSignature signature;
      try {
        signature = FunctionSignature.fromJson(
          symbol,
          jsonDecode(sigRow.signatureJson) as Map<String, dynamic>,
        );
      } catch (e) {
        // Malformed signature JSON — log and skip. Better than aborting
        // the whole pass on one bad row.
        stderr.writeln(
            '[HookBindingSeeder] signature JSON parse failed for "$symbol": $e');
        continue;
      }

      final result = _classifier.classify(
        functionName: symbol,
        signature: signature,
        decompilation: d.sourceText,
        dataSymbols: dataSymbols,
      );
      if (result == null) continue;

      final body = result.hook.code;
      final existing = await _db.findArtifactByBody(body);
      final int artifactId;
      if (existing != null) {
        artifactId = existing.id;
      } else {
        artifactId = await _db.addArtifact(
          artifactType: 'renode_hook',
          artifactData: body,
          origin: 'user',
          architecture: 'ARM',
          targetSymbolName: symbol,
          intrinsicScore: 0.5,
        );
        newArtifacts++;
      }

      // The catalog template's Hook carries the Renode scope (3rd arg
      // to AddHookAtSymbol) — null for stateless returnHook, the
      // function name for incrementHook, the protocol name for comms
      // templates, etc. Thread it onto the binding so the synthesizer's
      // iteration apply re-deploys with the same scope the template
      // expected.
      bindings[symbol] = HookBinding(
        artifactId: artifactId,
        fidelity: _fidelityForRule(result.ruleName),
        provenance: 'classifier:${result.ruleName}',
        createdAt: now,
        scope: result.hook.scope,
      );
      classified++;
    }

    stderr.writeln('[HookBindingSeeder] elfHash=${elfHash.substring(0, 8)}…: '
        '$classified classified, $skipped skipped, '
        '$noSignature without-signature, $emptyDecomp empty-decomp, '
        '$newArtifacts new artifact${newArtifacts == 1 ? '' : 's'} inserted');
    return bindings;
  }

  /// Walk [bindings] in place, re-classifying any symbol whose binding
  /// has `provenance` starting with `classifier:` and no scope set.
  /// Updates the existing binding with the catalog template's scope
  /// (preserves artifactId / fidelity / provenance / createdAt) so a
  /// pre-scope-migration project regains stateful-hook correctness on
  /// next open.
  ///
  /// Idempotent: bindings that already have a scope (or whose
  /// provenance is `user` / `llm:*` / `harness*`) are skipped. LLM and
  /// user-provenance bindings without scope are left alone — the
  /// per-creation-site policy assigns their scope at *creation* time,
  /// not retroactively.
  ///
  /// Returns the number of bindings upgraded.
  Future<int> upgradeBindingsMissingScope({
    required String elfHash,
    required Map<String, HookBinding> bindings,
  }) async {
    final affected = bindings.entries
        .where((e) =>
            e.value.scope == null &&
            e.value.provenance.startsWith('classifier:'))
        .map((e) => e.key)
        .toList();
    if (affected.isEmpty) return 0;

    final dsRows = await _db.dataSymbolsFor(elfHash);
    final dataSymbols = <String, DataSymbol>{
      for (final r in dsRows)
        r.symbolName: DataSymbol(
          name: r.symbolName,
          address: r.address,
          type: r.typeName,
          size: r.size,
        ),
    };

    var upgraded = 0;
    for (final symbol in affected) {
      final sigRow = await _db.getSignatureFor(
        elfHash: elfHash,
        symbolName: symbol,
      );
      if (sigRow == null) continue;
      final decomp = await _db.decompilationFor(
        elfHash: elfHash,
        functionName: symbol,
      );
      if (decomp == null || decomp.isEmpty) continue;
      final FunctionSignature signature;
      try {
        signature = FunctionSignature.fromJson(
          symbol,
          jsonDecode(sigRow.signatureJson) as Map<String, dynamic>,
        );
      } catch (e) {
        stderr.writeln('[HookBindingSeeder] migration signature parse '
            'failed for "$symbol": $e');
        continue;
      }
      final result = _classifier.classify(
        functionName: symbol,
        signature: signature,
        decompilation: decomp,
        dataSymbols: dataSymbols,
      );
      if (result == null) continue;
      if (result.hook.scope == null) continue;
      bindings[symbol] = bindings[symbol]!.copyWith(scope: result.hook.scope);
      upgraded++;
    }
    if (upgraded > 0) {
      stderr.writeln('[HookBindingSeeder] elfHash=${elfHash.substring(0, 8)}…: '
          '$upgraded binding${upgraded == 1 ? '' : 's'} '
          'upgraded with scope from re-classification');
    }
    return upgraded;
  }

  /// Map a classifier rule name (e.g. `rule-3-counter-global`) to its
  /// fidelity per §2.1: rules 1 and 2 are generic-template matches and
  /// score 0.25; rules 3 through 7 are specialized patterns and score
  /// 0.5.
  static double _fidelityForRule(String ruleName) {
    if (ruleName.startsWith('rule-1-') || ruleName.startsWith('rule-2-')) {
      return 0.25;
    }
    return 0.5;
  }
}
