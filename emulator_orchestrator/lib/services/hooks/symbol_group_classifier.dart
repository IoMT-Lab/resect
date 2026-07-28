import '../../data/models/symbol_group.dart';
import '../comms/comms_classifier.dart' show tokenize;
import 'hook_catalog.dart';

/// Recognizes peripheral "object" groups from firmware symbol names and gives
/// each member a coherent, shared-scope hook.
///
/// The parse is **verb-anchored**, not positional. A name is tokenized (on `_`
/// AND camelCase), then scanned left-to-right for the first *role verb*
/// (Enable, Disable, Set, Get, Is…, Reset, Clear, Init…). The tokens *before*
/// the verb are the object (the group key / [SymbolGroup.scope]); the verb *is*
/// the role; any digit-bearing token *after* the verb (e.g. `Timer1`) is
/// appended to the scope so numbered instances don't share state.
///
/// Worked examples:
///   LL_RCC_LSI_Enable               -> [LL,RCC,LSI | Enable]          scope LL_RCC_LSI, enable
///   LL_RADIO_TIMER_EnableTimer1     -> [..TIMER | Enable | Timer1]    scope LL_RADIO_TIMER_Timer1
///   LL_RADIO_TIMER_IsEnabledTimer1  -> [..TIMER | Is,Enabled,Timer1]  scope LL_RADIO_TIMER_Timer1
///   BLEPLAT_CNTR_PacketSetDataPtr   -> [BLEPLAT,CNTR,Packet | Set..]  scope BLEPLAT_CNTR_Packet, set
///
/// A symbol with no recognized verb has no derivable object, so it is simply
/// dropped (not grouped) — which is why coincidental prefixes like `us_to`
/// never form a group. Comms symbols are excluded up front (pass them in
/// [classify]'s `exclude`), so grouping never touches the bus mechanism.
/// See the `symbol_groups` docs page.
class SymbolGroupClassifier {
  SymbolGroupClassifier({
    required this.catalog,
    this.minMembers = 2,
    this.minSubjectTokens = 2,
  });

  final HookCatalog catalog;

  /// A scope needs at least this many members to be emitted as a group.
  final int minMembers;

  /// The object (tokens before the verb) must carry at least this many
  /// non-framework tokens, so a bare `LL`/`HAL` prefix can't be an object.
  final int minSubjectTokens;

  static const _frameworkPrefixes = {'LL', 'HAL'};

  /// Group [symbols] into objects, skipping anything in [exclude] (typically
  /// the comms-assigned symbols). Sorted by scope for deterministic output.
  List<SymbolGroup> classify(
    Iterable<String> symbols, {
    Set<String> exclude = const {},
  }) {
    final buckets = <String, List<({String symbol, GroupMemberRole role})>>{};
    for (final symbol in symbols) {
      if (exclude.contains(symbol)) continue;
      final parsed = _parse(symbol);
      if (parsed == null) continue;
      (buckets[parsed.scope] ??= []).add((symbol: symbol, role: parsed.role));
    }

    final groups = <SymbolGroup>[];
    buckets.forEach((scope, members) {
      if (members.length < minMembers) return;
      final map = <String, GroupMember>{};
      for (final m in members) {
        final hook = _hookFor(m.role, scope);
        map[m.symbol] = GroupMember(
          role: m.role,
          code: hook?.code ?? '',
          scope: hook?.scope,
        );
      }
      groups.add(SymbolGroup(scope: scope, members: map));
    });

    groups.sort((a, b) => a.scope.compareTo(b.scope));
    return groups;
  }

  /// Parse one symbol into its object [scope] and role, or null when it has no
  /// recognized verb or no viable object.
  ({String scope, GroupMemberRole role})? _parse(String symbol) {
    final tokens = tokenize(symbol);
    if (tokens.length < 2) return null;

    var verbIndex = -1;
    GroupMemberRole? role;
    for (var i = 0; i < tokens.length; i++) {
      final r = _verbRole(tokens[i]);
      if (r != null) {
        verbIndex = i;
        role = r;
        break;
      }
    }
    if (role == null) return null; // no verb → not an object member

    final subject = tokens.sublist(0, verbIndex);
    final nonFramework = subject
        .where((t) => !_frameworkPrefixes.contains(t.toUpperCase()))
        .length;
    if (nonFramework < minSubjectTokens) return null;

    // Append any digit-bearing token from the predicate (the verb's target),
    // so numbered instances (Timer1/Timer2) get distinct scopes while a
    // single-instance object (LSI: no digit token) keeps one shared scope.
    final predicate = tokens.sublist(verbIndex + 1);
    final instanceTokens = predicate.where(_hasDigit).toList();
    final scope = [...subject, ...instanceTokens].join('_');
    if (scope.isEmpty) return null;
    return (scope: scope, role: role);
  }

  static bool _hasDigit(String s) =>
      s.codeUnits.any((c) => c >= 0x30 && c <= 0x39);

  /// The role for a single token, or null when the token isn't a known verb.
  /// Ordered so the is-family wins first (so `IsEnabled` reads as isReady, not
  /// enable). Only unambiguous verbs are recognized; anything else (Toggle,
  /// Config, Start/Stop, Wait, …) leaves the symbol ungrouped rather than
  /// guessing.
  GroupMemberRole? _verbRole(String token) {
    final t = token.toLowerCase();
    if (t.startsWith('is') ||
        t == 'ready' ||
        t == 'active' ||
        t == 'valid' ||
        t == 'present') {
      return GroupMemberRole.isReady;
    }
    if (t == 'clear') return GroupMemberRole.clear;
    if (t == 'reset') return GroupMemberRole.reset;
    if (t == 'enable') return GroupMemberRole.enable;
    if (t == 'disable') return GroupMemberRole.disable;
    if (t == 'deinit') return GroupMemberRole.deinit;
    if (t == 'init') return GroupMemberRole.init;
    if (t == 'get') return GroupMemberRole.get;
    if (t == 'set') return GroupMemberRole.set;
    return null;
  }

  /// The catalog hook for a role, scoped to the group key.
  ({String code, String? scope})? _hookFor(GroupMemberRole role, String scope) {
    switch (role) {
      case GroupMemberRole.enable:
      case GroupMemberRole.set:
        final h = catalog
            .build('write', {'scope': scope, 'value': 1, 'returnValue': 0});
        return (code: h.code, scope: h.scope);
      case GroupMemberRole.disable:
      case GroupMemberRole.reset:
      case GroupMemberRole.clear:
        final h = catalog
            .build('write', {'scope': scope, 'value': 0, 'returnValue': 0});
        return (code: h.code, scope: h.scope);
      case GroupMemberRole.isReady:
      case GroupMemberRole.get:
        final h = catalog.build('read', {'scope': scope, 'defaultValue': 0});
        return (code: h.code, scope: h.scope);
      case GroupMemberRole.init:
      case GroupMemberRole.deinit:
        final h = catalog.build('return', {'value': 0});
        return (code: h.code, scope: h.scope);
      case GroupMemberRole.unknown:
        return null;
    }
  }
}
