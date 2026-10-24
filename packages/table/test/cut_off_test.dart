/// A device whose own line is down is not a table whose jury has gone
/// (transport.dart, cutOff; client.dart, _judgeQuorum).
///
/// Alone at a table of bots, a person hears most of the table whatever
/// happens — there is nobody else to count — so a device that stopped
/// hearing the jurors took them for gone, and twenty seconds after the
/// half minute a juror is given, ended the game: juror quorum lost. On a
/// plane's satellite link the way in had stalled and the way out still
/// carried; the jurors heard every heartbeat, and were playing on. What
/// the device sends going unanswered says it is its own line, and the
/// game waits for it.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  /// Alone with three bots the backup jurors hold, at a bot's turn
  /// mid-play: where the table was when the line went.
  (SimTable, TableClient) atABotsTurn() {
    final t = SimTable(humans: 1, seed: 4, crypto: crypto, target: 30, lastResort: true);
    t.start();
    final ada = t.people[0].client;
    expect(
        t.clock.runUntil(() => ada.game.phase == Phase.playing && ada.game.tricksPlayed >= 3 && ada.game.currentSeat != 0,
            limitMs: 20 * 60 * 1000),
        isTrue,
        reason: 'reached a bot\'s turn mid-play');
    expect(ada.cutOff, isFalse, reason: 'its line up: ${ada.describe()}');
    return (t, ada);
  }

  for (final (fault, down, up) in [
    ('its way in stalled, its way out carrying', (SimNetwork n, PublicKey k) => n.deafen(k), (SimNetwork n, PublicKey k) => n.hearAgain(k)),
    ('its line down both ways', (SimNetwork n, PublicKey k) => n.goOffline(k), (SimNetwork n, PublicKey k) => n.comeOnline(k)),
  ]) {
    test('alone with the bots, $fault for a minute: the game waits for the line, and plays on', () {
      final (t, ada) = atABotsTurn();
      final key = ada.signer.publicKey;
      final (hand, tricks) = (ada.game.handNumber, ada.game.tricksPlayed);
      down(t.net, key);
      // What ended the game was fifty seconds of not hearing the jury;
      // a minute is past that, and short of the two a person is given
      // before the table takes their seat.
      t.clock.advance(TableTiming.standard.jurorSilenceMs + TableTiming.standard.quorumLostMs + 10 * 1000);
      expect((ada.game.handNumber, ada.game.tricksPlayed), (hand, tricks), reason: 'the table stood still here: it heard nothing');
      expect(ada.cutOff, isTrue, reason: 'what it sent went unanswered');
      expect(ada.failure, isNull, reason: 'the game not ended for its own line:\n${ada.describe()}');
      expect(ada.describe(), contains('cut off'), reason: 'and its account of itself says so');
      expect(ada.lineAccount, contains('cut off now, cut off 1 times'), reason: ada.lineAccount);
      // What cost the table its next hand: a bot seat taken off its
      // juror for a move this side could not hear, and the juror then
      // left out of the next draw, one short of the jury the bots need.
      expect(ada.letGo, isEmpty, reason: 'no juror taken for silent for a move it could not hear');
      expect(ada.escrowedAt(ada.game.handNumber), isEmpty, reason: 'no bot seat given up to the escrow');
      up(t.net, key);
      expect(t.clock.runUntil(() => !ada.cutOff, limitMs: 10 * 1000), isTrue, reason: 'the line back');
      expect(t.run(limitMs: 3 * 60 * 60 * 1000), isTrue, reason: 'the game played out:\n${ada.describe()}');
      expect(ada.failure, isNull);
      expect(ada.amSeated, isTrue, reason: 'still in the seat');
      final v = verifyRecord(t.spec, ada.record, juries: ada.juries, crypto: crypto, releases: ada.releases);
      expect(v.ok && v.complete, isTrue, reason: v.reason);
      t.stop();
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  test('cut off for good, the device never ends the game itself: it waits on its line', () {
    final (t, ada) = atABotsTurn();
    t.net.deafen(ada.signer.publicKey);
    t.clock.advance(10 * 60 * 1000);
    expect(ada.cutOff, isTrue);
    expect(ada.failure, isNull, reason: ada.describe());
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The other side of it: with the line up, a jury really gone still
  // ends the game, as it always has (quorum_lost_test.dart).
  test('alone with the bots, the line up and the jurors gone: the game ends, juror quorum lost', () {
    final (t, ada) = atABotsTurn();
    for (final j in t.jurors) {
      t.net.goOffline(j.signer.publicKey);
    }
    expect(t.clock.runUntil(() => ada.failure != null, limitMs: 5 * 60 * 1000), isTrue, reason: ada.describe());
    expect(ada.failure, Failure.jurorQuorumLost);
    expect(ada.cutOff, isFalse, reason: 'the relay answered all along');
    // What the device tells the operator of it: where, whom it heard and
    // when, and its line, with no key, card or name in it.
    final account = ada.lineAccount;
    expect(account, startsWith('juror quorum lost at h'));
    expect(account, contains('hears 0 of 0 other people; jury 4 drawn, 0 live, last heard'));
    expect(account, endsWith('line up, cut off 0 times'));
    for (final k in [ada.signer.publicKey, for (final j in t.jurors) j.signer.publicKey]) {
      expect(account, isNot(contains(k.substring(0, 4))), reason: 'no key in it: $account');
    }
    t.stop();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
