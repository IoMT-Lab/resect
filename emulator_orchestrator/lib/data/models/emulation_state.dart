/// Emulation state (stopped, running, paused).
///
/// Extracted from app_providers.dart to avoid Flutter dependencies
/// in the orchestrator layer, enabling headless (non-Flutter) usage.
enum EmulationState { stopped, running, paused }
