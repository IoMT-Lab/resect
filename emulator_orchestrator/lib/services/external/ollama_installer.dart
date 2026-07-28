import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../config/config_schema.dart' show which;

/// Phase update emitted by [OllamaInstaller.install]. The progress
/// dialog shows [message] verbatim and uses [done]/[total] to drive a
/// progress bar (bytes when downloading, null when indeterminate).
class OllamaInstallEvent {
  const OllamaInstallEvent(this.message, {this.done, this.total});
  final String message;
  final int? done;
  final int? total;
}

/// In-process Ollama installer/runner. Avoids the no-terminal /
/// no-sudo dead end the previous `curl … | sh` path hit by:
///
///   1. Downloading the official GitHub-release tarball straight from
///      `github.com/ollama/ollama/releases/latest` to a user-local
///      cache dir (no root, no PolicyKit prompt).
///   2. Extracting it under `~/.local/share/resect/ollama/` via the
///      system `tar` + `zstd` (both present on every modern Linux).
///   3. Spawning `ollama serve` on a non-default port (so we never
///      collide with a system Ollama if one's later installed) and
///      tracking the process handle for clean shutdown.
///
/// Detect order is: system `ollama` on PATH → our user-local copy.
/// If either exists, no download happens. If the system copy is
/// present we use its binary directly and skip the daemon-spawn (its
/// systemd unit already runs it).
class OllamaInstaller {
  OllamaInstaller({this.archOverride});

  /// Override the architecture string used to pick a release asset.
  /// Mostly for tests; leave null in production so we detect via
  /// `uname -m`.
  final String? archOverride;

  static const _localPort = 11435;
  static String get localHost => '127.0.0.1:$_localPort';

  /// Returns the absolute path to the `ollama` binary we should use,
  /// or null if none is available (caller should run [install] first).
  /// Prefers a system install (on PATH) over our user-local one.
  String? resolveBinary() {
    final systemPath = which('ollama');
    if (systemPath != null) return systemPath;
    final local = _localBinary;
    if (File(local).existsSync()) return local;
    return null;
  }

  /// True when a usable Ollama binary exists on this machine, either
  /// system-wide or under our user-local managed dir.
  bool get isInstalled => resolveBinary() != null;

  /// True when [resolveBinary] points at a system-installed binary
  /// (and so daemon lifecycle is handled by systemd / the OS).
  bool get isSystemInstall {
    final r = resolveBinary();
    return r != null && !r.startsWith(_installRoot);
  }

  /// Root of the user-local managed install. Lives under XDG
  /// `~/.local/share/resect/ollama/` so it doesn't pollute the
  /// project tree.
  static String get _installRoot {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, '.local', 'share', 'resect', 'ollama');
  }

  static String get _localBinary => p.join(_installRoot, 'bin', 'ollama');
  static String get _modelsDir => p.join(_installRoot, 'models');
  static String get _cacheDir => p.join(_installRoot, '.cache');

  /// Download + extract the Ollama tarball if no binary is on hand.
  /// No-op when [isInstalled]. Emits human-readable progress lines
  /// plus optional byte counters for the download phase.
  Stream<OllamaInstallEvent> install() async* {
    if (isInstalled) {
      yield const OllamaInstallEvent('Ollama already installed.');
      return;
    }
    final arch = await _detectArch();
    if (arch == null) {
      throw OllamaInstallerException(
        'Could not detect CPU architecture (uname -m failed). '
        "Resect's in-app Ollama installer supports linux-amd64 and "
        'linux-arm64.',
      );
    }
    yield const OllamaInstallEvent('Looking up the latest Ollama release…');
    final asset = await _resolveLatestAsset(arch);
    yield OllamaInstallEvent(
      'Downloading ${asset.name} (${_formatBytes(asset.size)})…',
      total: asset.size,
    );
    final tarball = File(p.join(_cacheDir, asset.name));
    await Directory(_cacheDir).create(recursive: true);
    await for (final ev in _download(asset, tarball)) {
      yield ev;
    }
    yield OllamaInstallEvent('Extracting to $_installRoot…');
    await Directory(_installRoot).create(recursive: true);
    await _extract(tarball.path, _installRoot);
    if (!File(_localBinary).existsSync()) {
      throw OllamaInstallerException(
        'Extraction completed but $_localBinary is missing. The '
        'tarball layout may have changed; please file an issue.',
      );
    }
    yield const OllamaInstallEvent('Ollama installed.');
  }

  /// Make sure an Ollama daemon is reachable on whichever host this
  /// installer manages. If [isSystemInstall], we trust the OS (systemd
  /// service started by the official install script) and just probe;
  /// otherwise we spawn `ollama serve` ourselves on [_localPort].
  ///
  /// Returns the `host:port` the caller should put in `LLM_OLLAMA_HOST`.
  Future<String> ensureDaemonRunning() async {
    if (await _ping(_systemHost)) return _systemHost;
    if (await _ping(localHost)) return localHost;
    if (isSystemInstall) {
      // Trust the OS — systemd should be running it; if it's not,
      // the user needs to start it themselves (`systemctl start ollama`).
      throw OllamaInstallerException(
        'Ollama is installed system-wide but the daemon at $_systemHost '
        "isn't responding. Try `systemctl start ollama`.",
      );
    }
    await _spawnDaemon();
    // Give the daemon a moment to bind before declaring success.
    for (var i = 0; i < 20; i++) {
      if (await _ping(localHost)) return localHost;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw OllamaInstallerException(
      'Spawned the local Ollama daemon but it never came up on $localHost. '
      'See $_installRoot/serve.log for details.',
    );
  }

  /// Stop the spawned daemon (if any). Safe to call multiple times.
  /// Called from the Riverpod provider's `onDispose` so the daemon
  /// dies when Resect closes — keeps things tidy across app sessions.
  Future<void> stopDaemon() async {
    final proc = _daemonProcess;
    _daemonProcess = null;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigterm);
    await proc.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  Process? _daemonProcess;
  static const _systemHost = 'localhost:11434';

  Future<void> _spawnDaemon() async {
    final bin = resolveBinary();
    if (bin == null) {
      throw OllamaInstallerException(
        'No Ollama binary available to spawn. Run install() first.',
      );
    }
    final logFile = File(p.join(_installRoot, 'serve.log'));
    final log = logFile.openWrite();
    // ProcessStartMode.normal (the default) — gives us stdio AND
    // exitCode. detachedWithStdio sounds tempting for a daemon, but
    // it makes `exitCode` throw "Bad state: Process is detached"
    // when we wire log-close to it. We don't actually need the
    // daemon to outlive Resect's process — [stopDaemon] is wired
    // through Riverpod onDispose, and if the app crashes hard the
    // orphaned daemon will still be reachable on the local port
    // (next launch picks it up via the _ping in ensureDaemonRunning).
    final proc = await Process.start(
      bin,
      ['serve'],
      environment: {
        ...Platform.environment,
        'OLLAMA_HOST': localHost,
        'OLLAMA_MODELS': _modelsDir,
      },
    );
    proc.stdout.transform(utf8.decoder).listen(log.write);
    proc.stderr.transform(utf8.decoder).listen(log.write);
    unawaited(proc.exitCode.then((_) => log.close()));
    _daemonProcess = proc;
  }

  /// HTTP GET against `/api/tags` to confirm the daemon is up at [host].
  Future<bool> _ping(String host) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await client.getUrl(Uri.parse('http://$host/api/tags'));
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _detectArch() async {
    if (archOverride != null) return archOverride;
    final r = await Process.run('uname', ['-m']);
    if (r.exitCode != 0) return null;
    final raw = (r.stdout as String).trim();
    return switch (raw) {
      'x86_64' || 'amd64' => 'amd64',
      'aarch64' || 'arm64' => 'arm64',
      _ => null,
    };
  }

  Future<_ReleaseAsset> _resolveLatestAsset(String arch) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/ollama/ollama/releases/latest'),
      );
      req.headers.add('Accept', 'application/vnd.github+json');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw OllamaInstallerException(
          'GitHub API returned ${resp.statusCode} when looking up '
          "Ollama's latest release.",
        );
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
      final targetName = 'ollama-linux-$arch.tar.zst';
      final match = assets.firstWhere(
        (a) => a['name'] == targetName,
        orElse: () => throw OllamaInstallerException(
          'No release asset named "$targetName" in '
          'github.com/ollama/ollama/releases/latest.',
        ),
      );
      return _ReleaseAsset(
        name: match['name'] as String,
        size: (match['size'] as num).toInt(),
        url: match['browser_download_url'] as String,
      );
    } finally {
      client.close();
    }
  }

  Stream<OllamaInstallEvent> _download(_ReleaseAsset asset, File dest) async* {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(asset.url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw OllamaInstallerException(
          'Downloading ${asset.url} returned HTTP ${resp.statusCode}.',
        );
      }
      final sink = dest.openWrite();
      var received = 0;
      var lastReported = 0;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          // Yield about once per MB to keep the UI snappy without
          // flooding the install dialog.
          if (received - lastReported >= 1 * 1024 * 1024) {
            lastReported = received;
            yield OllamaInstallEvent(
              'Downloaded ${_formatBytes(received)} / '
              '${_formatBytes(asset.size)}…',
              done: received,
              total: asset.size,
            );
          }
        }
      } finally {
        await sink.close();
      }
      yield OllamaInstallEvent(
        'Downloaded ${_formatBytes(received)}.',
        done: received,
        total: asset.size,
      );
    } finally {
      client.close();
    }
  }

  /// Extract `ollama-linux-<arch>.tar.zst` to [dest]. Shells to system
  /// `tar` with `--use-compress-program=unzstd` because Dart has no
  /// zstd codec built in, and zstd is on every modern Linux box.
  Future<void> _extract(String tarball, String dest) async {
    final r = await Process.run('tar', [
      '--use-compress-program=unzstd',
      '-xf',
      tarball,
      '-C',
      dest,
    ]);
    if (r.exitCode != 0) {
      throw OllamaInstallerException(
        'tar/zstd extraction of $tarball failed (exit ${r.exitCode}): '
        '${r.stderr}',
      );
    }
  }

  static String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.size,
    required this.url,
  });
  final String name;
  final int size;
  final String url;
}

class OllamaInstallerException implements Exception {
  OllamaInstallerException(this.message);
  final String message;
  @override
  String toString() => 'OllamaInstallerException: $message';
}
