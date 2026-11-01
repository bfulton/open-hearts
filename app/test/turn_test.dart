/// The ICE servers a device takes to a table: from the service's `turn`
/// handler, STUN alone when it has none, nothing on localhost.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/http.dart';
import 'package:open_hearts/net/licence.dart' show requestDigest;
import 'package:open_hearts/net/turn.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_sim/table_sim.dart';

import 'home_page_test.dart' show licenceThisDevice;

/// The service key home_page_test.dart's licences are signed for.
const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

void main() {
  final signer = FakeSigner('turn');

  /// A stand-in for the handler, answering [status] with [body].
  Future<({Uri url, Future<void> Function() stop, List<String> seen})> handler(int status, String body) async {
    final seen = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      seen.add('${req.method} ${req.uri.path} ${await utf8.decoder.bind(req).join()}');
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
    return (url: Uri.parse('http://127.0.0.1:${server.port}/api/turn'), stop: () => server.close(force: true), seen: seen);
  }

  test('credentials from the handler, the key in the request', () async {
    final h = await handler(200, jsonEncode({
      'iceServers': [
        {'urls': ['stun:stun.cloudflare.com:3478']},
        {'urls': ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:5349?transport=tcp'], 'username': 'u', 'credential': 'c'},
      ],
      'ttl': 14400,
    }));
    try {
      final servers = await iceServersFor(signer, endpoint: h.url);
      expect(servers, hasLength(2));
      expect(servers[1]['urls'], hasLength(2));
      expect(servers[1]['username'], 'u');
      expect(servers[1]['credential'], 'c');
      final [method, path, body] = h.seen.single.split(' ');
      expect('$method $path', 'POST /api/turn');
      // The key, and its signature over asking for TURN now: a key
      // alone is anybody's (licence.dart, signedAsk).
      final asked = jsonDecode(body) as Map<String, Object?>;
      expect(asked['key'], signer.publicKey);
      expect(asked['sig'], signer.sign(requestDigest('turn', signer.publicKey, asked['at'] as int)));
    } finally {
      await h.stop();
    }
  });

  test('a handler with none to give, or unreachable, leaves no servers, and so no channels', () async {
    final h = await handler(503, jsonEncode({'error': 'service not configured: OH_TURN_KEY_ID and OH_TURN_API_TOKEN'}));
    try {
      expect(await iceServersFor(signer, endpoint: h.url), isEmpty);
    } finally {
      await h.stop();
    }
    expect(await iceServersFor(signer, endpoint: Uri.parse('http://127.0.0.1:1/api/turn')), isEmpty);
    final nonsense = await handler(200, '<html>');
    try {
      expect(await iceServersFor(signer, endpoint: nonsense.url), isEmpty);
    } finally {
      await nonsense.stop();
    }
  });

  test('a handler that never answers is given its few seconds, and no servers after', () async {
    // It takes the request and says nothing: a worker that has hung. The
    // credentials are fetched beside the relays rather than in front of
    // them (live/lobby.dart), so nothing on the screen waits on this.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((_) {});
    try {
      final began = DateTime.now();
      final servers = await iceServersFor(signer,
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/api/turn'), timeout: const Duration(milliseconds: 300));
      expect(servers, isEmpty);
      expect(DateTime.now().difference(began), lessThan(const Duration(seconds: 3)));
    } finally {
      await server.close(force: true);
    }
  });

  test('the ask shows the licence this device holds, which names its account', () async {
    // As every ask of the service shows it (household.dart, askHandler):
    // a device just brought in is asked of its account by it before the
    // service's store where it asks has heard of it.
    SharedPreferences.setMockInitialValues({});
    Entitlement.current = Entitlement(service: _service);
    addTearDown(() => Entitlement.current = Entitlement());
    await licenceThisDevice();
    final h = await handler(200, jsonEncode({'iceServers': [{'urls': ['stun:stun.cloudflare.com:3478']}]}));
    try {
      await iceServersFor(await Identity.signer(), endpoint: h.url);
      final [_, _, body] = h.seen.single.split(' ');
      expect((jsonDecode(body) as Map)['licence'], Entitlement.current.licence!.toJson());
    } finally {
      await h.stop();
    }
  });

  test('no endpoint, no servers: localhost connects directly', () async {
    expect(await iceServersFor(signer), isEmpty);
  });

  test('the answer is read strictly', () {
    expect(parseIceServers('{"iceServers":[{"urls":"stun:a"},{"urls":[]},{"urls":["turn:b"],"username":"u","credential":"c"}]}'), [
      {'urls': ['stun:a']},
      {'urls': ['turn:b'], 'username': 'u', 'credential': 'c'},
    ]);
    expect(parseIceServers('{"iceServers":[]}'), isNull);
    expect(parseIceServers('{"iceServers":{"urls":"x"}}'), isNull);
    expect(parseIceServers('[]'), isNull);
    expect(parseIceServers('nope'), isNull);
  });

  test('a refusal comes back whole: its status and what it said', () async {
    // postJson keeps only what was taken, which is all the ICE servers
    // need. The handlers a person is waiting on — a code, a claim —
    // need the reason as well (net/household.dart), so the POST under
    // both hands back the status and the body either way.
    final h = await handler(409, '{"error":"that code has been used"}');
    try {
      final answer = await post(h.url, '{"key":"x"}');
      expect(answer.status, 409);
      expect(answer.body, '{"error":"that code has been used"}');
      expect(await postJson(h.url, '{"key":"x"}'), isNull, reason: 'and what was refused was not taken');
      expect(h.seen, hasLength(2));
    } finally {
      await h.stop();
    }
  });
}
