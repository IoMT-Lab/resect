import 'dart:convert';
import 'dart:io';

import 'package:emulator_orchestrator/config/component.dart';
import 'package:test/test.dart';

/// The HTTP daemon probe backing `LlmHookGenComponent.detect()`:
/// a responsive Ollama at the configured host (e.g. the docker stack's
/// `ollama:11434` service, where no local binary exists) must be
/// detected via `GET /api/tags`; anything unresponsive returns null so
/// detect falls back to the binary-managed path.
void main() {
  HttpServer? server;

  tearDown(() async {
    await server?.close(force: true);
    server = null;
  });

  Future<String> serve(
      Future<void> Function(HttpRequest request) handler) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen(handler);
    return '127.0.0.1:${server!.port}';
  }

  test('parses tags from /api/tags per the documented shape', () async {
    final host = await serve((req) async {
      expect(req.method, 'GET');
      expect(req.uri.path, '/api/tags');
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'models': [
            {'name': 'gemma4:e4b', 'size': 1},
            {'name': 'nomic-embed-text:latest', 'size': 2},
          ],
        }));
      await req.response.close();
    });
    expect(await ollamaTagsViaHttp(host),
        ['gemma4:e4b', 'nomic-embed-text:latest']);
  });

  test('empty model list parses as empty (daemon up, nothing pulled)',
      () async {
    final host = await serve((req) async {
      req.response.write(jsonEncode({'models': <Object>[]}));
      await req.response.close();
    });
    expect(await ollamaTagsViaHttp(host), isEmpty);
  });

  test('non-200 responses return null', () async {
    final host = await serve((req) async {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });
    expect(await ollamaTagsViaHttp(host), isNull);
  });

  test('malformed JSON returns null', () async {
    final host = await serve((req) async {
      req.response.write('{ not json');
      await req.response.close();
    });
    expect(await ollamaTagsViaHttp(host), isNull);
  });

  test('connection refused returns null (detect falls back to binary)',
      () async {
    // Bind + close to get a port that is definitely not listening.
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close(force: true);
    expect(await ollamaTagsViaHttp('127.0.0.1:$port'), isNull);
  });
}
