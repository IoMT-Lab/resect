/// A hook value carrying both its Python source and the optional Renode
/// execution scope (3rd arg to `AddHookAtSymbol`).
///
/// Used by the Comms-bus virtualization path, where each protocol's hooks
/// share a scope ('i2c' / 'spi' / 'uart') to coordinate via Python globals
/// — and by any future stateful hook flow. Forced overrides and synthesis-
/// resolved hooks continue to flow through the existing `Map<String,String>`
/// paths (scope = null, equivalent to today's behavior).
typedef HookSpec = ({String code, String? scope});
