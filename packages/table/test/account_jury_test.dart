/// A jury draws nobody of an account seated at the table, by whichever of
/// its devices (docs/04-live-play.md): a player's laptop online while
/// their phone sits at the table is the player, not a stranger.
library;

import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

/// Every key any jury of [t] drew, as each side holds them.
Set<PublicKey> drawnAt(SimTable t) => {
      for (final c in [...t.clients, for (final j in t.jurors) if (j.client != null) j.client!])
        for (final d in c.juries) ...d.event.jurors,
    };

void main() {
  test('a seated player\'s other device is online, and never drawn', () {
    // Eight strangers and the player's own second device: a draw of six
    // from nine, every hand, would take it often were it a stranger.
    final t = SimTable(humans: 2, seed: 5, jurors: 7);
    final p = t.presence!;
    final seated = t.people[0].client.signer.publicKey;
    final laptop = SimJuror(FakeSigner('laptop'), t.net, t.clock, account: seated);
    // And a stranger's laptop, arriving the same way: drawn as anyone is.
    final strangers = SimJuror(FakeSigner('strangers-laptop'), t.net, t.clock);
    for (final j in [laptop, strangers]) {
      t.jurors.add(j);
      p.register(j);
    }
    t.start();
    expect(t.run(), isTrue, reason: t.people[0].client.describe());
    expect(p.online(withinMs: 15000), contains(laptop.signer.publicKey), reason: 'it is there to be drawn');
    final drawn = drawnAt(t);
    expect(drawn, contains(strangers.signer.publicKey), reason: 'a device like it, of nobody at the table, is drawn');
    expect(drawn, isNot(contains(laptop.signer.publicKey)));
    expect(laptop.client, isNull, reason: 'never summoned');
  });

  test('at a sealed table the snapshot a jury is drawn from holds no device of a seated account', () async {
    // A held bot seat's cards go to its juror: the player's other device
    // holding one would be the player seeing a bot's hand.
    final crypto = await rememberedCrypto();
    final t = SimTable(humans: 3, seed: 9, jurors: 6, crypto: crypto);
    final p = t.presence!;
    final seated = t.people[1].client.signer.publicKey;
    final laptop = SimJuror(FakeSigner('laptop-9'), t.net, t.clock, crypto: crypto, account: seated);
    t.jurors.add(laptop);
    p.register(laptop);
    t.start();
    expect(t.run(), isTrue);
    for (final c in t.survivors) {
      for (final d in c.juries) {
        expect(d.event.snapshot, isNot(contains(laptop.signer.publicKey)), reason: 'not even in the snapshot drawn from');
      }
      expect(verifyRecord(t.spec, c.record, juries: c.juries, crypto: crypto).ok, isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
