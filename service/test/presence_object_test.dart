/// Presence on the object that carries it, and presence when that
/// object is not there.
///
/// The relay a deployed build prefers for presence keeps one object
/// per tag and wants the tag in the URL (docs/06-service.md,
/// `service/do/`), which is the only thing about it a client has to
/// know. Everything else is the arrangement presence already had: the
/// beats go to every relay the device can write to, so the public
/// relays carry them too, and a device that cannot reach the object —
/// or is running before it was ever deployed — is online exactly as it
/// was before.
library;

import 'dart:io';

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => installNativeSchnorr());

  /// A port with nothing listening on it: taken, then given back.
  Future<int> closedPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Waits for [what], a few seconds at most.
  Future<void> until(String what, bool Function() holds) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!holds()) {
      if (DateTime.now().isAfter(deadline)) fail(what);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('the tag goes in the path, and the tag is what everyone meets on', () async {
    final object = JsRelay();
    await object.serve();
    final marked = Uri.parse('${object.url}/$tagMark');
    final a = RelayPresence(relays: [marked], signer: SchnorrSigner.generate(), everyMs: 300);
    final b = RelayPresence(relays: [marked], signer: SchnorrSigner.generate(), everyMs: 300);
    // The mark is gone by the time a socket is opened: presence put
    // its own topic where the object's name goes.
    expect(a.relays.single, Uri.parse('${object.url}/${RelayPresence.topic}'));
    await Future.wait([a.ready, b.ready]).timeout(const Duration(seconds: 10));
    await until('the two devices did not see each other on the object',
        () => a.online(withinMs: 3000).contains(b.signer.publicKey) && b.online(withinMs: 3000).contains(a.signer.publicKey));

    // A client that opens the same host without a tag is somewhere
    // else: an object is reached by its name and by nothing else.
    final elsewhere = RelayPresence(relays: [object.url], signer: SchnorrSigner.generate(), everyMs: 300);
    await elsewhere.ready.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(elsewhere.online(withinMs: 3000), {elsewhere.signer.publicKey});
    expect(a.online(withinMs: 3000).contains(elsewhere.signer.publicKey), isFalse);

    a.close();
    b.close();
    elsewhere.close();
    await object.close();
  });

  test('the object not answering is not the end of presence: the relays carry it', () async {
    // Nothing has ever been deployed at this address — which is the
    // state of the world the day a build ships with it in the list.
    final absent = Uri.parse('ws://127.0.0.1:${await closedPort()}/$tagMark');
    final relay = Relay();
    await relay.serve();
    final a = RelayPresence(relays: [absent, relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    final b = RelayPresence(relays: [absent, relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    await Future.wait([a.ready, b.ready]).timeout(const Duration(seconds: 10));
    await until('presence did not fall back to the relays',
        () => a.online(withinMs: 3000).contains(b.signer.publicKey) && b.online(withinMs: 3000).contains(a.signer.publicKey));
    // A relay that is not there is not a relay refusing: nothing is
    // said to the player, because nothing is wrong for them.
    expect(a.refusal, isNull);
    expect(b.refusal, isNull);
    a.close();
    b.close();
    await relay.close();
  });

  test('a device on the object and a device on the relays alone still see each other', () async {
    final object = JsRelay();
    final relay = Relay();
    await object.serve();
    await relay.serve();
    final both = [Uri.parse('${object.url}/$tagMark'), relay.url];
    final ours = RelayPresence(relays: both, signer: SchnorrSigner.generate(), everyMs: 300);
    // An older build, a filtered network, a device that simply cannot
    // reach the object: it reads the public relays and nothing else.
    final theirs = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    await Future.wait([ours.ready, theirs.ready]).timeout(const Duration(seconds: 10));
    await until('the two did not see each other across the object and the relay',
        () => ours.online(withinMs: 3000).contains(theirs.signer.publicKey) && theirs.online(withinMs: 3000).contains(ours.signer.publicKey));
    ours.close();
    theirs.close();
    await object.close();
    await relay.close();
  });
}
