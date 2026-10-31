/// The ratings the house chooses a pool's bots by (lib/src/ratings.dart):
/// the results on the relay, and its own as it says them.
library;

import 'dart:io';

import 'package:engine/engine.dart';
import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  late Relay relay;
  final house = SchnorrSigner.generate();
  final bot = Persona.roster.first.id;
  setUp(() async {
    relay = Relay(house: house.publicKey);
    await relay.serve();
  });
  tearDown(() => relay.close());

  var tables = 0;

  /// A rated game the bot [bot] won against somebody, by the house.
  GameResult won({String? account}) {
    final key = SchnorrSigner.generate().publicKey;
    return GameResult(
      table: (++tables).toRadixString(16).padLeft(32, '0'),
      rated: true,
      at: 0,
      v: GameResult.version,
      state: TableState.finished.name,
      endN: 1,
      endHash: 'ab' * 32,
      seats: [
        SeatResult(human: false, bot: bot, total: 0, fromStart: true),
        SeatResult(human: true, key: key, account: account ?? key.substring(0, 32), total: 40, fromStart: true),
      ],
    );
  }

  /// [results], said on the results tag by the house, as it says them.
  Future<void> said(List<GameResult> results) async {
    final t = RelayTransport(relays: [relay.url], signer: house, table: GameResult.tag);
    await t.ready;
    for (final r in results) {
      expect(await t.announceTaken(r.toJson()), isTrue);
    }
    t.close();
  }

  final start = botPrior(bot)!.mu;

  test('the ratings are the results the house said, and then each it says', () async {
    await said([won(), won()]);
    final ratings = Ratings(relays: [relay.url], signer: house);
    expect(ratings.ledger.of(bot).mu, start, reason: 'the bots at their starting ratings until the results are read');
    await ratings.load();
    expect(ratings.ledger.gamesOf(bot), 2);
    expect(ratings.ledger.of(bot).mu, greaterThan(start), reason: 'two games won');
    final before = ratings.ledger.of(bot).mu;
    ratings.fold(won());
    expect(ratings.ledger.gamesOf(bot), 3, reason: 'its own, as it says it');
    expect(ratings.ledger.of(bot).mu, greaterThan(before));
    // A result whose seats are not each an account's once stands for
    // nothing, as the ledger reads one (results.dart, licensed).
    final shared = won(account: 'cd' * 16);
    ratings.fold(GameResult(
        table: shared.table, rated: true, at: 0, v: GameResult.version, state: shared.state, endN: 1, endHash: shared.endHash,
        seats: [...shared.seats, shared.seats.last]));
    expect(ratings.ledger.gamesOf(bot), 3);
  });

  test('a result said while the results are being read is folded once they are, and once', () async {
    final onRelay = won();
    await said([onRelay]);
    final ratings = Ratings(relays: [relay.url], signer: house);
    final loading = ratings.load();
    expect(identical(loading, ratings.load()), isTrue, reason: 'read once');
    // The house says two results as the read goes on: one the relay
    // already holds, and one it does not.
    ratings.fold(onRelay);
    ratings.fold(won());
    await loading;
    expect(ratings.ledger.gamesOf(bot), 2, reason: 'the relay\'s, and the one it did not have; neither twice');
  });

  test('with no relay answering, the bots start at their starting ratings, and the house\'s own results still count', () async {
    final nobody = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = nobody.port;
    await nobody.close();
    final ratings = Ratings(
        relays: [Uri.parse('ws://127.0.0.1:$port/$tagMark')],
        signer: house,
        first: const Duration(milliseconds: 500),
        rest: const Duration(milliseconds: 100));
    final loading = ratings.load();
    ratings.fold(won());
    await loading;
    expect(ratings.ledger.gamesOf(bot), 1, reason: 'said meanwhile');
    ratings.fold(won());
    expect(ratings.ledger.gamesOf(bot), 2);
  });
}
