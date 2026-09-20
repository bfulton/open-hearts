/// Saying you are going, and the draw preferring whoever has stayed.
///
/// Both are about the same thing: a hand's escrow rests on the jurors
/// it drew still being there when a bot seat has to be opened
/// (docs/04-live-play.md, "The sizing"), and the levers on that are
/// how quickly a departure is noticed and how likely the drawn are to
/// stay — not how many are drawn.
library;

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => installNativeSchnorr());

  /// Waits for [what], a few seconds at most.
  Future<void> until(String what, bool Function() holds) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!holds()) {
      if (DateTime.now().isAfter(deadline)) fail(what);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('a device that says it is going is gone at once, not after a missed beat', () async {
    final relay = Relay();
    await relay.serve();
    // Beats far enough apart that waiting one out would fail this
    // test: what is being measured is the saying, not the timing out.
    final a = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    final b = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    await Future.wait([a.ready, b.ready]).timeout(const Duration(seconds: 10));
    await until('the two did not see each other', () => a.online(withinMs: 60000).contains(b.signer.publicKey));

    b.leaving();
    await until('a going was not heard', () => !a.online(withinMs: 60000).contains(b.signer.publicKey));
    // And only of itself: the event is signed by the key it is about,
    // so nobody can say somebody else has gone.
    expect(b.online(withinMs: 60000), contains(a.signer.publicKey));

    // And it stays gone: saying you are going also stops saying you
    // are here, or the next beat would undo it a moment later.
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(a.online(withinMs: 60000).contains(b.signer.publicKey), isFalse,
        reason: 'a device that has gone does not announce itself back');

    // Coming back is the app returning to the foreground (Duty.back),
    // and it is heard — with the run started over, since a key that
    // went and returned is newly here, not settled.
    b.silent = false;
    await until('coming back was not heard', () => a.online(withinMs: 60000).contains(b.signer.publicKey));
    expect(a.settled(withinMs: 60000, forMs: 500).contains(b.signer.publicKey), isFalse,
        reason: 'a key back from being gone starts its run again');

    a.close();
    b.close();
    await relay.close();
  });

  test('settled is who has been announcing a while, or is seated at a table', () async {
    final relay = Relay();
    await relay.serve();
    final watcher = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    final old = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    await Future.wait([watcher.ready, old.ready]).timeout(const Duration(seconds: 10));
    await until('the first was not seen', () => watcher.online(withinMs: 60000).contains(old.signer.publicKey));
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    // A newcomer, and a newcomer that says it is at a table.
    final fresh = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300);
    final playing = RelayPresence(
        relays: [relay.url], signer: SchnorrSigner.generate(), everyMs: 300, status: RelayPresence.seated);
    await Future.wait([fresh.ready, playing.ready]).timeout(const Duration(seconds: 10));
    await until('the newcomers were not seen',
        () => watcher.online(withinMs: 60000).containsAll([fresh.signer.publicKey, playing.signer.publicKey]));

    final settled = watcher.settled(withinMs: 60000, forMs: 1000);
    expect(settled, contains(old.signer.publicKey), reason: 'here long enough to be evidence of anything');
    expect(settled, isNot(contains(fresh.signer.publicKey)), reason: 'just arrived, and says nothing else');
    expect(settled, contains(playing.signer.publicKey), reason: 'mid-game, so it has a reason to stay');
    // This device is always its own: it knows perfectly well it is here.
    expect(settled, contains(watcher.signer.publicKey));
    // And settled is a narrowing of online, never more than it.
    expect(watcher.online(withinMs: 60000).containsAll(settled), isTrue);

    for (final p in [watcher, old, fresh, playing]) {
      p.close();
    }
    await relay.close();
  });
}
