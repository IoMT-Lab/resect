/// Events emitted by [VagrantTestRunner] during a CI/CD test run.
sealed class VagrantTestEvent {
  const VagrantTestEvent();
}

/// A test step started executing.
class VagrantTestStepStarted extends VagrantTestEvent {
  final VagrantTestStepId step;
  const VagrantTestStepStarted(this.step);
}

/// A log line was emitted (stdout or stderr) for the currently running step.
class VagrantTestLogLine extends VagrantTestEvent {
  final VagrantTestStepId step;
  final String line;
  const VagrantTestLogLine(this.step, this.line);
}

/// A step completed successfully.
class VagrantTestStepPassed extends VagrantTestEvent {
  final VagrantTestStepId step;
  const VagrantTestStepPassed(this.step);
}

/// A step failed.
class VagrantTestStepFailed extends VagrantTestEvent {
  final VagrantTestStepId step;
  final String reason;
  const VagrantTestStepFailed(this.step, this.reason);
}

/// The entire test run completed (all steps passed, or one failed).
class VagrantTestComplete extends VagrantTestEvent {
  final bool passed;
  const VagrantTestComplete(this.passed);
}

/// The test run was cancelled by the user.
class VagrantTestCancelled extends VagrantTestEvent {
  const VagrantTestCancelled();
}

/// The four ordered test steps.
enum VagrantTestStepId {
  provision('Provision VM'),
  filesPresent('Project files present'),
  toolStarts('Resect tool starts'),
  synthesisRuns('Synthesis runs');

  final String label;
  const VagrantTestStepId(this.label);
}
