/// A page reloaded mid-game comes back to its seat (journal.dart): a
/// new client, from what the device kept and nothing else, reads its
/// own word back, picks up its deal secret, is carried forward by the
/// table, and plays on in the seat — the record of the game as sound
/// as one nobody left.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await DealCrypto.load());

  // Where in a hand the page goes: in the deal, in the pass, in the
  // middle of the play, and in hand two, with a whole hand behind it.
  final moments = <(String, bool Function(TableClient c))>[
    ('the deal', (c) => c.game.handNumber == 0 && c.game.phase == Phase.dealing && c.record.length > 4),
    ('the pass', (c) => c.game.handNumber == 0 && c.game.phase == Phase.passing),
    ('mid-play', (c) => c.game.handNumber == 0 && c.game.phase == Phase.playing && c.game.tricksPlayed >= 4),
    ('hand two', (c) => c.game.handNumber == 1 && c.game.phase == Phase.playing && c.game.tricksPlayed >= 2),
  ];
  for (final (moment, at) in moments) {
    test('reloaded in $moment, the seat is still theirs and the game plays out', () {
      final t = SimTable(humans: 4, seed: 11, crypto: crypto, target: 30, journals: {1: TableJournal()});
      t.start();
      final reloading = t.people[1].client;
      expect(t.clock.runUntil(() => at(reloading), limitMs: 20 * 60 * 1000), isTrue, reason: 'reached $moment');
      final key = reloading.signer.publicKey;
      t.reload(1);
      expect(t.run(limitMs: 3 * 60 * 60 * 1000), isTrue, reason: 'every survivor\'s game over');
      final back = t.people[1].client;
      expect(back.amSeated, isTrue, reason: 'still in the seat');
      for (final c in t.clients) {
        expect(c.holders[1], isA<HumanSeat>().having((h) => h.key, 'key', key), reason: 'nobody put a bot in it');
        expect(c.game.totals, t.clients.first.game.totals, reason: 'one game, the same everywhere');
      }
      final v = verifyRecord(t.spec, back.record, juries: back.juries, crypto: crypto, releases: back.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
      t.stop();
    });
  }

  test('alone with three bots the jury holds, reloaded mid-play: back in the seat, the bots played on', () {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, target: 30, lastResort: true, journals: {0: TableJournal()});
    t.start();
    final ada = t.people[0].client;
    expect(t.clock.runUntil(() => ada.game.phase == Phase.playing && ada.game.tricksPlayed >= 3, limitMs: 20 * 60 * 1000), isTrue);
    t.reload(0);
    expect(t.run(limitMs: 3 * 60 * 60 * 1000), isTrue);
    final back = t.people[0].client;
    expect(back.amSeated, isTrue);
    expect(back.holders[0], isA<HumanSeat>());
    final v = verifyRecord(t.spec, back.record, juries: back.juries, crypto: crypto, releases: back.releases);
    expect(v.ok && v.complete, isTrue, reason: v.reason);
    t.stop();
  });

  test('away too long: a bot has the seat, and the page that comes back is told so and plays no more', () {
    // A table with a jury, as every live table has: a seat's escrow is
    // with its jurors, and the bot that takes it plays on from there.
    final t = SimTable(humans: 2, seed: 9, crypto: crypto, jurors: 4, target: 30, journals: {1: TableJournal()});
    t.start();
    final c = t.people[1].client;
    expect(t.clock.runUntil(() => c.game.phase == Phase.playing && c.game.tricksPlayed >= 2, limitMs: 20 * 60 * 1000), isTrue);
    t.reload(1, awayMs: 60 * 1000);
    final back = t.people[1].client;
    expect(t.clock.runUntil(() => !back.amSeated, limitMs: 60 * 1000), isTrue, reason: 'it learns it is out');
    expect(back.holders[1], isA<BotSeat>());
    expect(t.run(limitMs: 3 * 60 * 60 * 1000), isTrue, reason: 'the others finish with the bot');
    t.stop();
  });
}
