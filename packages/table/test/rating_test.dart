import 'dart:convert';

import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('winning against equals raises a rating and settles it; losing lowers it', () {
    const me = Rating.fresh;
    final won = rate(me, [for (var i = 0; i < 3; i++) (opponent: Rating.fresh, score: 1.0)]);
    expect(won.mu, greaterThan(me.mu));
    expect(won.phi, lessThan(me.phi));
    final lost = rate(me, [for (var i = 0; i < 3; i++) (opponent: Rating.fresh, score: 0.0)]);
    expect(lost.mu, lessThan(me.mu));
    // A settled player moves less than a newcomer.
    final settled = rate(const Rating(mu: 1500, phi: 60), [for (var i = 0; i < 3; i++) (opponent: Rating.fresh, score: 1.0)]);
    expect(settled.mu - 1500, lessThan(won.mu - 1500));
  });

  test('beating stronger opponents is worth more than beating weaker ones', () {
    const me = Rating(mu: 1500, phi: 100);
    final vsStrong = rate(me, [(opponent: const Rating(mu: 1800, phi: 60), score: 1.0)]);
    final vsWeak = rate(me, [(opponent: const Rating(mu: 1200, phi: 60), score: 1.0)]);
    expect(vsStrong.mu - 1500, greaterThan(vsWeak.mu - 1500));
  });

  test('a rated game rates people and the bots that started it; a leaver is last; a replacement has no stake', () {
    final a = FakeSigner('a').publicKey;
    final b = FakeSigner('b').publicKey;
    final spec = TableSpec(id: 't1', seed: 1, rated: true, seats: [
      HumanSeat(a),
      const BotSeat(Persona.romeo),
      HumanSeat(b),
      const BotSeat(Persona.juliet),
    ]);
    // b left; Cyrano finished the seat with the lowest total of all.
    final finalHolders = [HumanSeat(a), const BotSeat(Persona.romeo), const BotSeat(Persona.cyrano), const BotSeat(Persona.juliet)];
    final r = GameResult.of(spec, finalHolders, [60, 90, 20, 100]);
    expect(r.seats.length, 5);
    final ledger = Ledger()..apply(r);
    expect(ledger.of(a).mu, greaterThan(1500), reason: 'a beat everyone with a stake');
    expect(ledger.of(b).mu, lessThan(1500), reason: 'b left, and finishes last whatever the seat scored');
    expect(ledger.of('Romeo').mu, greaterThan(ledger.of('Juliet').mu));
    expect(ledger.gamesOf('Cyrano'), 0, reason: 'a replacement bot is not rated');
    expect(ledger.gamesOf('Romeo'), 1);
    // Unrated: nothing moves.
    final unrated = Ledger()..apply(GameResult(table: 't2', rated: false, seats: r.seats, at: 0));
    expect(unrated.gamesOf(a), 0);
  });

  test('a result stands when a majority of its humans published it, and only a seat may vouch', () {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final c = SchnorrSigner.generate();
    final stranger = SchnorrSigner.generate();
    final spec = TableSpec(id: 't3', seed: 1, rated: true, seats: [
      HumanSeat(a.publicKey),
      HumanSeat(b.publicKey),
      HumanSeat(c.publicKey),
      const BotSeat(Persona.westley),
    ]);
    final honest = GameResult.of(spec, spec.seats, [10, 50, 60, 80]);
    final forged = GameResult.of(spec, spec.seats, [80, 50, 60, 10]);
    NostrEvent say(Signer s, GameResult r, int at) => NostrEvent.sign(s, kind: TableKinds.lobby, content: jsonEncode(r.toJson()), tags: [
          ['t', GameResult.tag]
        ], createdAt: at);
    // Only a publishes: not a majority of three.
    expect(Ledger.from([say(a, honest, 1)]).gamesOf(a.publicKey), 0);
    // a and b: stands.
    expect(Ledger.from([say(a, honest, 1), say(b, honest, 2)]).gamesOf(a.publicKey), 1);
    // A stranger's vouching counts for nothing, and a forged version with one voice loses to the honest two.
    final l = Ledger.from([say(a, honest, 1), say(b, honest, 2), say(c, forged, 3), say(stranger, forged, 4)]);
    expect(l.of(a.publicKey).mu, greaterThan(1500));
  });

  test('a tally is what a player\'s finished games come to', () {
    final me = FakeSigner('me').publicKey;
    final you = FakeSigner('you').publicKey;
    GameResult game(String table, List<int> totals, {bool rated = true, bool iLeft = false}) => GameResult(
          table: table,
          rated: rated,
          at: 0,
          seats: [
            SeatResult(human: true, key: me, account: me, total: totals[0], fromStart: true, left: iLeft),
            SeatResult(human: true, key: you, account: you, total: totals[1], fromStart: true),
            SeatResult(human: false, bot: 'Romeo', total: totals[2], fromStart: true),
            SeatResult(human: false, bot: 'Juliet', total: totals[3], fromStart: true),
          ],
        );

    final games = [
      game('t1', [20, 50, 60, 70]), // won
      game('t2', [80, 30, 40, 50]), // lost
      game('t3', [45, 45, 60, 70]), // tied at the bottom, which the game does not break
      game('t4', [10, 90, 90, 90], rated: false), // won, but not for the rating
      game('t5', [99, 20, 30, 40], iLeft: true), // left
    ];

    final all = Tally.of(me, games);
    expect(all.games, 5);
    expect(all.won, 3, reason: 'the two outright and the tie');
    expect(all.best, 10);
    expect(all.average, closeTo((20 + 80 + 45 + 10 + 99) / 5, 0.001));

    final rated = Tally.of(me, games, rated: true);
    expect(rated.games, 4, reason: 'the unrated game is a game, but not a rated one');
    expect(rated.won, 2);
    expect(rated.best, 20);

    // A seat its player left is played and not won, whatever the bot
    // that finished it went on to score.
    expect(Tally.of(me, [games.last]).won, 0);
    // And the ledger keeps what it folded, which is where these come from.
    final ledger = Ledger();
    for (final g in games) {
      ledger.apply(g);
    }
    expect(ledger.standing.length, 5, reason: 'unrated games are not rated, but they were still played');
    // t2, t3's tie, and t5 — where the lowest of those still at the
    // table was theirs, whatever the seat I left went on to score.
    expect(Tally.of(you, ledger.standing).won, 3);
  });
}
