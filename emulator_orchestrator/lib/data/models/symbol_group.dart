/// An "object" inferred from firmware symbol names: a family of member
/// functions that share a name prefix (the [scope]) and are hooked together.
///
/// Example: `LL_RCC_LSI_Enable` / `LL_RCC_LSI_Disable` / `LL_RCC_LSI_IsReady`
/// form one group with `scope == 'LL_RCC_LSI'` and three members whose roles
/// are enable / disable / isReady. See the `symbol_groups` docs page.
///
/// Produced by `SymbolGroupClassifier` from symbol names alone. Comms symbols
/// are excluded before grouping, so a group never contains a bus symbol.
library;

/// A per-project decision about an [object group](@ref) that overrides the
/// synthesizer's default deterministic-on-fault behavior. Stored on the
/// project keyed by group scope; absent = default (auto-apply on member fault).
enum GroupOverrideState {
  /// Pre-install the group's coherent member hooks at the start of every run.
  forced,

  /// Never apply the group — members fall back to per-symbol handling even if
  /// one faults.
  suppressed,
}

/// What one member function does within its [SymbolGroup], inferred from the
/// trailing action component of its symbol name.
enum GroupMemberRole {
  enable,
  disable,
  isReady,
  get,
  set,
  reset,
  clear,
  init,
  deinit,

  /// The action word wasn't recognized. The member is kept for reference but
  /// gets no coherent group hook (empty [GroupMember.code]); it falls back to
  /// normal per-symbol classification.
  unknown,
}

/// One member function of a [SymbolGroup].
class GroupMember {
  const GroupMember({
    required this.role,
    required this.code,
    this.scope,
  });

  final GroupMemberRole role;

  /// The coherent hook body for this member's role, scoped to the group.
  /// Empty when [role] is [GroupMemberRole.unknown].
  final String code;

  /// The Renode hook scope — the group key for stateful roles
  /// (write/read/increment), null for stateless roles (return) and unknown.
  final String? scope;

  bool get hasHook => code.isNotEmpty;
}

/// A recognized object: its shared [scope] (the group key, e.g. `LL_RCC_LSI`)
/// and its member functions keyed by symbol name.
class SymbolGroup {
  const SymbolGroup({required this.scope, required this.members});

  final String scope;
  final Map<String, GroupMember> members;

  /// Members that have a coherent hook to install (role != unknown).
  Iterable<MapEntry<String, GroupMember>> get hookableMembers =>
      members.entries.where((e) => e.value.hasHook);
}
