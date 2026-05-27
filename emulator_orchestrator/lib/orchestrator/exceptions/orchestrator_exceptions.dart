/// Base exception for all orchestration errors.
class OrchestrationException implements Exception {
  final String message;
  final dynamic cause;

  OrchestrationException(this.message, [this.cause]);

  @override
  String toString() =>
      'OrchestrationException: $message${cause != null ? '\nCaused by: $cause' : ''}';
}

/// Emulation-specific exception.
///
/// Thrown when emulation operations fail (start, pause, resume, reset).
class EmulationException extends OrchestrationException {
  EmulationException(super.message, [super.cause]);

  @override
  String toString() =>
      'EmulationException: $message${cause != null ? '\nCaused by: $cause' : ''}';
}

/// Analysis-specific exception.
///
/// Thrown when analysis operations fail (call graph generation, layout).
class AnalysisException extends OrchestrationException {
  AnalysisException(super.message, [super.cause]);

  @override
  String toString() =>
      'AnalysisException: $message${cause != null ? '\nCaused by: $cause' : ''}';
}

/// Exception for unsaved changes.
///
/// Thrown when attempting to close an emulator with unsaved changes.
/// UI should prompt user for confirmation before proceeding.
class UnsavedChangesException extends OrchestrationException {
  UnsavedChangesException(super.message);

  @override
  String toString() => 'UnsavedChangesException: $message';
}
