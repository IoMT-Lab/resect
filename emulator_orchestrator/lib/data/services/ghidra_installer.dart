import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../config/config_schema.dart' show which;
import '../../config/env_config.dart';

/// Phase update emitted by [GhidraInstaller.install] — shape matches
/// `OllamaInstallEvent`. The install dialog uses [done]/[total] to
/// drive a progress bar (bytes during the download phase, null
/// otherwise) and shows [message] in the log.
class GhidraInstallEvent {
  const GhidraInstallEvent(this.message, {this.done, this.total});
  final String message;
  final int? done;
  final int? total;
}

/// In-process Ghidra installer. Mirrors [OllamaInstaller] but:
///
///   - Ghidra ships as a single zip (~570 MB) on GitHub releases —
///     no `.tar.zst` codec dependency, just `unzip` (universal).
///   - Ghidra is not a long-running daemon; the installer's job
///     ends at "binary present + config var set". `analyzeHeadless`
///     is invoked per-extraction by `SignaturesService`, not held
///     open here.
///   - Ghidra requires a JVM (Java 21+ for current releases). The
///     installer detects this *before* the download — a 570 MB
///     download is too expensive to discover a missing JVM after.
///
/// Detect order:
///   1. `GHIDRA_DIR` in `resect.config` points at a directory with
///      `support/analyzeHeadless` → use it.
///   2. `which ghidra` returns a path → resolve to its install dir.
///   3. Our user-local copy at
///      `~/.local/share/resect/ghidra/ghidra_<version>_PUBLIC/`.
///   4. None → unavailable.
class GhidraInstaller {
  GhidraInstaller({this.javaBinaryOverride});

  /// Override the path used to detect Java. Tests only; null in
  /// production falls back to `which java`.
  final String? javaBinaryOverride;

  /// Root of the user-local managed Ghidra install. The unzipped
  /// Ghidra release expands to a versioned subdirectory inside this
  /// root (e.g. `ghidra_12.1.2_PUBLIC/`).
  static String get _installRoot {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, '.local', 'share', 'resect', 'ghidra');
  }

  /// Root of the user-local managed Temurin JRE install. The
  /// extracted JRE expands to `jdk-<ver>-jre/` inside this root.
  /// Separate from [_installRoot] so wiping one doesn't take the
  /// other with it.
  static String get _jdkRoot {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, '.local', 'share', 'resect', 'jdk');
  }

  static String get _cacheDir => p.join(_installRoot, '.cache');
  static String get _jdkCacheDir => p.join(_jdkRoot, '.cache');

  /// Absolute path to the install dir Ghidra unpacked into, or null
  /// if no managed install is present. Reads the cache dir for the
  /// presence of an unpacked release subdir.
  String? get _managedInstallDir {
    final root = Directory(_installRoot);
    if (!root.existsSync()) return null;
    for (final entry in root.listSync()) {
      if (entry is Directory &&
          p.basename(entry.path).startsWith('ghidra_') &&
          p.basename(entry.path).endsWith('_PUBLIC')) {
        return entry.path;
      }
    }
    return null;
  }

  /// Returns the install directory (the one containing
  /// `support/analyzeHeadless`) that callers should use, or null
  /// when no usable install is available.
  String? resolveInstallDir() {
    final fromConfig = EnvConfig.load().get('GHIDRA_DIR') ?? '';
    if (fromConfig.isNotEmpty &&
        File(p.join(fromConfig, 'support', 'analyzeHeadless'))
            .existsSync()) {
      return fromConfig;
    }
    final systemPath = which('ghidra');
    if (systemPath != null) {
      // `which ghidra` may return a launcher script; walk up to find
      // the install dir (the one with support/analyzeHeadless).
      var dir = File(systemPath).parent;
      for (var i = 0; i < 4; i++) {
        if (File(p.join(dir.path, 'support', 'analyzeHeadless'))
            .existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
    }
    final managed = _managedInstallDir;
    if (managed != null &&
        File(p.join(managed, 'support', 'analyzeHeadless'))
            .existsSync()) {
      return managed;
    }
    return null;
  }

  bool get isInstalled => resolveInstallDir() != null;

  /// Locate the managed Temurin JRE we may have extracted under
  /// [_jdkRoot] (e.g. `~/.local/share/resect/jdk/jdk-21.0.11+10-jre/`).
  /// Returns the directory path that should be set as `JAVA_HOME`, or
  /// null if no managed JRE is on disk.
  String? get _managedJavaHome {
    final root = Directory(_jdkRoot);
    if (!root.existsSync()) return null;
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final base = p.basename(entry.path);
      if (!base.startsWith('jdk-')) continue;
      if (!File(p.join(entry.path, 'bin', 'java')).existsSync()) continue;
      return entry.path;
    }
    return null;
  }

  /// Path to a usable `java` binary (must be JDK/JRE 21+), or null
  /// when none is found. Resolution order:
  ///   1. Test override
  ///   2. Managed Temurin JRE under [_jdkRoot] (we always trust this
  ///      since we put it there)
  ///   3. System `java` on PATH, *if* `java -version` reports >= 21
  Future<String?> resolveJavaBinary() async {
    final overridePath = javaBinaryOverride;
    if (overridePath != null) {
      return File(overridePath).existsSync() ? overridePath : null;
    }
    final managed = _managedJavaHome;
    if (managed != null) {
      return p.join(managed, 'bin', 'java');
    }
    final systemPath = which('java');
    if (systemPath == null) return null;
    return await _isJava21OrNewer(systemPath) ? systemPath : null;
  }

  /// Path to set as `JAVA_HOME` when invoking `analyzeHeadless`, or
  /// null. analyzeHeadless's shell wrapper reads JAVA_HOME first; if
  /// unset it falls back to PATH lookup. We always set this when we
  /// have a managed JRE so we never accidentally use a too-old
  /// system Java.
  Future<String?> resolveJavaHome() async {
    final managed = _managedJavaHome;
    if (managed != null) return managed;
    // No managed JRE — let analyzeHeadless use whatever's on PATH.
    // resolveJavaBinary() has already verified it's >= 21 by the
    // time the caller reaches install completion.
    return null;
  }

  /// Run `java -version` and check the major version. Temurin emits
  /// the version on stderr in the form
  /// `openjdk version "21.0.11" …` — we parse the first int.
  Future<bool> _isJava21OrNewer(String javaBinary) async {
    try {
      final r = await Process.run(javaBinary, ['-version']);
      final out =
          '${r.stdout as String}${r.stderr as String}';
      final match =
          RegExp(r'version "(\d+)').firstMatch(out);
      if (match == null) return false;
      final major = int.tryParse(match.group(1)!) ?? 0;
      return major >= 21;
    } catch (_) {
      return false;
    }
  }

  /// Detect + install Ghidra (and its prereqs). Emits phase events
  /// for the dialog. Two phases:
  ///
  ///   1. **JRE 21** — if no usable Java is on PATH OR under our
  ///      managed JDK dir, download Temurin 21 JRE (~52 MB) from
  ///      GitHub releases and extract it. No sudo, no apt.
  ///   2. **Ghidra** — download the official release zip and
  ///      extract it.
  ///
  /// Both phases stream byte-level progress so the install dialog's
  /// progress bar can advance smoothly. Throws on any prereq
  /// failure (e.g. unsupported architecture).
  Stream<GhidraInstallEvent> install() async* {
    // Phase 1: ensure a usable JRE is available.
    yield* _ensureJre();
    // Phase 2: ensure Ghidra is unpacked.
    if (isInstalled) {
      yield const GhidraInstallEvent('Ghidra already installed.');
      await _persistInstallDir();
      return;
    }
    yield const GhidraInstallEvent('Looking up the latest Ghidra release…');
    final asset = await _resolveLatestAsset();
    yield GhidraInstallEvent(
      'Downloading ${asset.name} (${_formatBytes(asset.size)})…',
      total: asset.size,
    );
    await Directory(_cacheDir).create(recursive: true);
    final zipPath = p.join(_cacheDir, asset.name);
    await for (final ev in _download(asset, File(zipPath))) {
      yield ev;
    }
    yield GhidraInstallEvent('Extracting to $_installRoot…');
    await Directory(_installRoot).create(recursive: true);
    await _extract(zipPath, _installRoot);
    final installDir = _managedInstallDir;
    if (installDir == null ||
        !File(p.join(installDir, 'support', 'analyzeHeadless'))
            .existsSync()) {
      throw GhidraInstallerException(
        'Extraction completed but $_installRoot does not contain a '
        'ghidra_<version>_PUBLIC/ directory with support/analyzeHeadless. '
        'The release layout may have changed; please file an issue.',
      );
    }
    await _persistInstallDir();
    yield const GhidraInstallEvent('Ghidra installed.');
  }

  /// Write the resolved install directory into `resect.config` so
  /// downstream consumers (SignaturesService, the call-graph
  /// enrichment path) read the same value without re-running detect.
  Future<void> _persistInstallDir() async {
    final dir = resolveInstallDir();
    if (dir == null) return;
    final cfg = EnvConfig.load();
    if ((cfg.get('GHIDRA_DIR') ?? '') != dir) {
      cfg.set('GHIDRA_DIR', dir);
      await cfg.save();
    }
  }

  /// Ensure a usable JRE 21+ is available. Skips when system or
  /// managed Java is present and recent enough; otherwise downloads
  /// Temurin's JRE for the host architecture.
  Stream<GhidraInstallEvent> _ensureJre() async* {
    final existing = await resolveJavaBinary();
    if (existing != null) {
      yield GhidraInstallEvent('Java ready ($existing).');
      return;
    }
    final arch = await _detectJdkArch();
    if (arch == null) {
      throw GhidraInstallerException(
        'Could not detect a supported CPU architecture for the '
        'Temurin JRE download (need x64 or aarch64 Linux). uname -m '
        'returned something unexpected.',
      );
    }
    yield const GhidraInstallEvent(
        'No Java 21+ found — fetching Temurin JDK release info…');
    final asset = await _resolveJdkAsset(arch);
    yield GhidraInstallEvent(
      'Downloading ${asset.name} (${_formatBytes(asset.size)})…',
      total: asset.size,
    );
    await Directory(_jdkRoot).create(recursive: true);
    final cacheDir = Directory(_jdkCacheDir);
    await cacheDir.create(recursive: true);
    final tarPath = p.join(cacheDir.path, asset.name);
    await for (final ev in _download(asset, File(tarPath))) {
      yield ev;
    }
    yield GhidraInstallEvent('Extracting Temurin JRE to $_jdkRoot…');
    await _extractTarGz(tarPath, _jdkRoot);
    final jdkHome = _managedJavaHome;
    if (jdkHome == null) {
      throw GhidraInstallerException(
        'Extracted Temurin JRE but no `jdk-*` directory landed under '
        '$_jdkRoot. The release layout may have changed.',
      );
    }
    yield GhidraInstallEvent('Temurin JRE ready at $jdkHome.');
  }

  /// `x64` or `aarch64` — matches Temurin asset naming. Returns null
  /// for architectures Temurin doesn't ship a JRE for.
  Future<String?> _detectJdkArch() async {
    final r = await Process.run('uname', ['-m']);
    if (r.exitCode != 0) return null;
    final raw = (r.stdout as String).trim();
    return switch (raw) {
      'x86_64' || 'amd64' => 'x64',
      'aarch64' || 'arm64' => 'aarch64',
      _ => null,
    };
  }

  Future<_ReleaseAsset> _resolveJdkAsset(String arch) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(
        'https://api.github.com/repos/adoptium/temurin21-binaries/'
        'releases/latest',
      ));
      req.headers.add('Accept', 'application/vnd.github+json');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw GhidraInstallerException(
          'GitHub API returned ${resp.statusCode} when looking up '
          "Temurin's latest release.",
        );
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
      // Match the GNU/Linux **JDK** tarball for our arch — Ghidra
      // requires a JDK (not a JRE) per its `launch.properties`. We
      // tried the JRE first; analyzeHeadless rejected it with
      // "JAVA_HOME environment specifies unsupported java version".
      // Explicitly avoid alpine-linux (musl) and debugimage /
      // testimage builds.
      final match = assets.firstWhere(
        (a) {
          final name = a['name'] as String;
          return name.startsWith('OpenJDK21U-jdk_') &&
              name.contains('_${arch}_linux_') &&
              name.endsWith('.tar.gz');
        },
        orElse: () => throw GhidraInstallerException(
          'No OpenJDK21U-jdk_${arch}_linux_*.tar.gz asset in the '
          'latest Temurin 21 release.',
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

  /// Extract a `.tar.gz` to [dest] via the system `tar`. Same shape
  /// as the existing `unzip` call for the Ghidra zip; we don't drag
  /// in a Dart-side gz codec for one file type.
  Future<void> _extractTarGz(String tarPath, String dest) async {
    final r = await Process.run('tar', ['-xzf', tarPath, '-C', dest]);
    if (r.exitCode != 0) {
      throw GhidraInstallerException(
        'tar -xzf on $tarPath failed (exit ${r.exitCode}): ${r.stderr}',
      );
    }
  }

  Future<_ReleaseAsset> _resolveLatestAsset() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(
        'https://api.github.com/repos/NationalSecurityAgency/ghidra/'
        'releases/latest',
      ));
      req.headers.add('Accept', 'application/vnd.github+json');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw GhidraInstallerException(
          'GitHub API returned ${resp.statusCode} when looking up '
          "Ghidra's latest release.",
        );
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
      // Match `ghidra_<ver>_PUBLIC_<date>.zip` — there's exactly one
      // such asset per release, but we filter explicitly in case
      // upstream ever adds platform-specific zips alongside.
      final match = assets.firstWhere(
        (a) {
          final name = a['name'] as String;
          return name.startsWith('ghidra_') &&
              name.endsWith('.zip') &&
              name.contains('_PUBLIC_');
        },
        orElse: () => throw GhidraInstallerException(
          'No ghidra_*_PUBLIC_*.zip asset in '
          'github.com/NationalSecurityAgency/ghidra/releases/latest.',
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

  Stream<GhidraInstallEvent> _download(
      _ReleaseAsset asset, File dest) async* {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(asset.url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw GhidraInstallerException(
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
          // Yield about once per MB so the progress bar advances
          // smoothly without flooding the install dialog.
          if (received - lastReported >= 1 * 1024 * 1024) {
            lastReported = received;
            yield GhidraInstallEvent(
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
      yield GhidraInstallEvent(
        'Downloaded ${_formatBytes(received)}.',
        done: received,
        total: asset.size,
      );
    } finally {
      client.close();
    }
  }

  /// Shell out to `unzip` (universal on Linux). `-q` suppresses the
  /// per-file output that would otherwise flood the install dialog —
  /// the user wants "extracted" not 600+ filenames.
  Future<void> _extract(String zipPath, String dest) async {
    final r = await Process.run('unzip', ['-q', '-o', zipPath, '-d', dest]);
    if (r.exitCode != 0) {
      throw GhidraInstallerException(
        'unzip extraction of $zipPath failed (exit ${r.exitCode}): '
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

class GhidraInstallerException implements Exception {
  GhidraInstallerException(this.message);
  final String message;
  @override
  String toString() => 'GhidraInstallerException: $message';
}
