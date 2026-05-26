import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/app_paths.dart';
import '../data/models/emulator.dart';
import 'vagrant_test_event.dart';

/// Runs a four-step CI/CD validation of the resect project inside a fresh
/// Vagrant VM (ubuntu/jammy64). The repo is synced from the host so the VM
/// always reflects the current state of development.
///
/// Usage:
/// ```dart
/// final runner = VagrantTestRunner();
/// runner.events.listen((event) { ... });
/// await runner.start(emulator: emulator, repoRoot: AppPaths.repoRoot);
/// ```
class VagrantTestRunner {
  final _controller = StreamController<VagrantTestEvent>.broadcast();
  Stream<VagrantTestEvent> get events => _controller.stream;

  Process? _activeProcess;
  bool _cancelled = false;
  String? _workDir;

  /// Start the test run.
  ///
  /// [emulator] must have non-null [elfFilePath] and [baseImagePath].
  /// [repoRoot] is the workspace root (parent of `emulation_engine/`).
  /// [workDir] is where the Vagrantfile is written; defaults to a temp dir.
  Future<void> start({
    required Emulator emulator,
    String? repoRoot,
    String? workDir,
  }) async {
    _cancelled = false;

    final root = repoRoot ?? p.dirname(AppPaths.findEngineDir());
    _workDir = workDir ?? p.join(Directory.systemTemp.path, 'resect_test_${const Uuid().v4()}');

    await Directory(_workDir!).create(recursive: true);

    try {
      // Write the Vagrantfile and provision script
      await _writeVagrantfiles(root);

      // Step 1: vagrant up (provision test)
      await _runStep(
        VagrantTestStepId.provision,
        () => _runVagrant(['up', '--no-tty'], VagrantTestStepId.provision),
      );
      if (_cancelled) return;

      // Step 2: upload project files then verify they're present
      await _runStep(
        VagrantTestStepId.filesPresent,
        () async {
          final elfPath = emulator.elfFilePath!;
          final replPath = emulator.baseImagePath!;
          final elfBasename = p.basename(elfPath);
          final replBasename = p.basename(replPath);

          await _runVagrant(
            ['upload', elfPath, '/resect-project/$elfBasename'],
            VagrantTestStepId.filesPresent,
          );
          await _runVagrant(
            ['upload', replPath, '/resect-project/$replBasename'],
            VagrantTestStepId.filesPresent,
          );
          await _runSsh(
            'ls -lh /resect-project/$elfBasename /resect-project/$replBasename',
            VagrantTestStepId.filesPresent,
          );
        },
      );
      if (_cancelled) return;

      // Step 3: resect CLI starts
      await _runStep(
        VagrantTestStepId.toolStarts,
        () => _runSsh(
          'cd /resect/emulator_orchestrator && dart run bin/cli.dart --help',
          VagrantTestStepId.toolStarts,
        ),
      );
      if (_cancelled) return;

      // Step 4: synthesis runs (crash = fail; synthesis failure = pass)
      await _runStep(
        VagrantTestStepId.synthesisRuns,
        () async {
          final elfBasename = p.basename(emulator.elfFilePath!);
          final replBasename = p.basename(emulator.baseImagePath!);
          final startFrom = emulator.emulationConfig.startFrom != null
              ? '--start-from ${emulator.emulationConfig.startFrom}'
              : '';
          await _runSsh(
            'cd /resect/emulator_orchestrator && '
            'dart run bin/cli.dart synthesize '
            '--elf /resect-project/$elfBasename '
            '--repl /resect-project/$replBasename '
            '--engine-dir /resect/emulation_engine '
            '$startFrom'.trim(),
            VagrantTestStepId.synthesisRuns,
            acceptSynthesisNonConvergence: true,
          );
        },
      );

      if (!_cancelled) {
        _emit(const VagrantTestComplete(true));
      }
    } catch (e) {
      if (!_cancelled) {
        _emit(VagrantTestComplete(false));
      }
    } finally {
      await _cleanup();
      _controller.close();
    }
  }

  /// Cancel the running test and destroy the VM.
  Future<void> cancel() async {
    _cancelled = true;
    _activeProcess?.kill(ProcessSignal.sigterm);
    await _cleanup();
    _emit(const VagrantTestCancelled());
    await _controller.close();
  }

  // -------------------------------------------------------------------------

  Future<void> _runStep(
    VagrantTestStepId step,
    Future<void> Function() body,
  ) async {
    _emit(VagrantTestStepStarted(step));
    try {
      await body();
      _emit(VagrantTestStepPassed(step));
    } catch (e) {
      _emit(VagrantTestStepFailed(step, e.toString()));
      rethrow;
    }
  }

  Future<void> _runVagrant(
    List<String> args,
    VagrantTestStepId step,
  ) async {
    await _runCommand('vagrant', args, step, workingDir: _workDir);
  }

  Future<void> _runSsh(
    String command,
    VagrantTestStepId step, {
    bool acceptSynthesisNonConvergence = false,
  }) async {
    // Use `vagrant ssh -c` to run a command inside the VM.
    // Prepend the PATH so that dart, pipenv, and python3.12 are all found in
    // non-interactive SSH sessions (which have a stripped PATH on Ubuntu).
    const dartBin = '/opt/flutter/bin/dart';
    final vmCommand = command.replaceAll('dart run', '$dartBin run');
    const pathPrefix =
        'export PATH=/opt/flutter/bin:/usr/local/bin:\$PATH &&';
    await _runCommand(
      'vagrant',
      ['ssh', '-c', '$pathPrefix $vmCommand'],
      step,
      workingDir: _workDir,
      acceptSynthesisNonConvergence: acceptSynthesisNonConvergence,
    );
  }

  Future<void> _runCommand(
    String executable,
    List<String> args,
    VagrantTestStepId step, {
    String? workingDir,
    // When true, exit code 1 (synthesis did not converge) is acceptable.
    // Exit codes >= 2 indicate tool crashes and are still treated as failures.
    bool acceptSynthesisNonConvergence = false,
  }) async {
    if (_cancelled) return;

    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDir,
    );
    _activeProcess = process;

    // Stream stdout and stderr to the event sink, collecting lines to inspect
    final allLines = <String>[];

    final stdoutFuture = process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      allLines.add(line);
      _emit(VagrantTestLogLine(step, line));
    });

    final stderrFuture = process.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      allLines.add(line);
      _emit(VagrantTestLogLine(step, '[stderr] $line'));
    });

    await Future.wait([stdoutFuture, stderrFuture]);
    final exitCode = await process.exitCode;
    _activeProcess = null;

    if (exitCode == 0) return;

    // Check if the output indicates a hard failure (backend crash, connection
    // refused, etc.) — these are never acceptable even when we tolerate
    // synthesis non-convergence.
    const crashIndicators = [
      'Could not connect to backend',
      'Application startup failed',
      'Connection refused',
      'Failed to connect',
      'FileNotFoundError',
      'No such file or directory',
      'Failed to generate call graph',
    ];
    final output = allLines.join('\n');
    final hasCrash = crashIndicators.any((s) => output.contains(s));

    if (exitCode == 1 && acceptSynthesisNonConvergence && !hasCrash) {
      _emit(VagrantTestLogLine(
          step, '[info] Synthesis did not converge (exit 1) — tool ran correctly'));
      return;
    }
    throw VagrantTestException(
      'Command exited with code $exitCode: $executable ${args.join(' ')}',
    );
  }

  void _emit(VagrantTestEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<void> _cleanup() async {
    if (_workDir == null) return;
    try {
      final result = await Process.run(
        'vagrant',
        ['destroy', '-f'],
        workingDirectory: _workDir,
      );
      if (result.exitCode != 0) {
        stderr.writeln('Warning: vagrant destroy failed: ${result.stderr}');
      }
    } catch (_) {
      // Best-effort cleanup
    }
  }

  Future<void> _writeVagrantfiles(String repoRoot) async {
    final vagrantfile = '''
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.synced_folder "${repoRoot.replaceAll('\\', '/')}", "/resect", type: "virtualbox"
  config.vm.provider "virtualbox" do |vb|
    vb.memory = 4096
    vb.cpus = 4
  end
  config.vm.provision "shell", path: "test_provision.sh"
end
''';

    const provisionSh = r'''#!/usr/bin/env bash
set -e

# ---------------------------------------------------------------------------
# Mirror install.sh sections 1-3 (skip VirtualBox/Vagrant — not needed in VM)
# ---------------------------------------------------------------------------

# Section 1: System packages (same as install.sh)
apt-get update -q
apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  gcc-arm-none-eabi \
  git git-lfs \
  curl unzip wget lsb-release \
  software-properties-common \
  libsqlite3-dev

# Python (same as install.sh — read version from Pipfile)
PYTHON_VERSION=$(grep 'python_version' /resect/emulation_engine/Pipfile \
  | grep -oP '"\K[^"]+')
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update -q
apt-get install -y "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" python3-pip
pip3 install --quiet pipenv

# Section 2: Flutter SDK (same as install.sh but installed to /opt/flutter
# since there is no persistent home dir, and run as vagrant user)
FLUTTER_DIR="/opt/flutter"
git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
chown -R vagrant:vagrant "$FLUTTER_DIR"
sudo -u vagrant -H "$FLUTTER_DIR/bin/flutter" --disable-analytics

# Section 3: Python backend
chmod +x /resect/emulation_engine/renode_1.16.0-dotnet_portable/renode
sudo -u vagrant -H \
  env PATH="$FLUTTER_DIR/bin:/usr/local/bin:$PATH" PIPENV_IGNORE_VIRTUALENVS=1 \
  bash -c 'cd /resect/emulation_engine && pipenv install --quiet'

# Section 4: Dart workspace
sudo -u vagrant -H \
  env PATH="$FLUTTER_DIR/bin:/usr/local/bin:$PATH" \
  "$FLUTTER_DIR/bin/flutter" pub get --directory /resect

# ---------------------------------------------------------------------------
# VM-specific setup
# ---------------------------------------------------------------------------

# Warm up Renode's .NET single-file extraction cache (first run is slow)
echo "Warming up Renode..."
timeout 30 /resect/emulation_engine/renode_1.16.0-dotnet_portable/renode \
  --disable-gui --server-mode --server-mode-port 19999 &
RENODE_PID=$!
sleep 10
kill $RENODE_PID 2>/dev/null || true
wait $RENODE_PID 2>/dev/null || true

# Create working directories
mkdir -p /resect-project /tmp/renode_logs
chown vagrant:vagrant /resect-project /tmp/renode_logs

echo "Resect dev environment ready."
''';

    await File(p.join(_workDir!, 'Vagrantfile')).writeAsString(vagrantfile);
    await File(p.join(_workDir!, 'test_provision.sh')).writeAsString(provisionSh);
  }
}

class VagrantTestException implements Exception {
  final String message;
  VagrantTestException(this.message);

  @override
  String toString() => 'VagrantTestException: $message';
}
