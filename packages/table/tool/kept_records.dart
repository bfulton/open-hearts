/// Kept games, as the library of their day wrote them, for the test that
/// every later library still reads them (test/kept_records_test.dart).
///
/// Run once, with the library built on arkworks 0.3, to write
/// test/fixtures/: a sealed game of four people to its end, and one of
/// three people and a bot where a person leaves mid-hand and the jury
/// carries the table on. They are not to be written again: a record
/// kept is what it is, and a library that cannot read the ones its
/// predecessor wrote has broken every game already kept.
///
///     cd packages/table && dart run tool/kept_records.dart [path/to/libdeal.so]
///
/// The library named, or crypto/deal's build; asked directly, never
/// through remembered answers.
library;

// A tool's output is what it prints.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

Future<void> main(List<String> args) async {
  await installNativeSchnorr();
  final crypto = await DealCrypto.load(libraryPath: args.isEmpty ? null : args.first);
  Directory('test/fixtures').createSync(recursive: true);

  void keep(String name, SimTable t, TableClient c, Map<int, String> names) {
    final json = jsonEncode(GameRecord.of(c, names: names).toJson());
    final v = verifyRecord(c.spec, c.record, juries: c.juries, crypto: crypto, releases: c.releases);
    if (!v.ok || !v.complete) throw StateError('$name does not verify: ${v.reason}');
    File('test/fixtures/$name.json.gz').writeAsBytesSync(gzip.encode(utf8.encode(json)));
    print('$name: ${c.record.length} decisions, ${c.juries.length} juries, ${c.releases.length} releases, '
        '${(json.length / 1024).toStringAsFixed(0)} KB');
  }

  // Four people, played out: keys, shuffles, tokens, passes, plays and
  // audits, every one of them made by the library. Real keys, a real
  // table id, and each seat an account's by a licence the browser rig's
  // service signed (BIP-340's published pair, as tool/game_fixture.dart),
  // so the review page checks it in the browser as it would a kept game
  // (e2e/flows.mjs).
  const rigSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
  Licence licenceOf(PublicKey key) {
    final account = key.substring(0, 32);
    final until = DateTime.utc(2099, 1, 1);
    final unsigned = Licence(key: key, account: account, until: until, plan: 'year', signature: '');
    return Licence(key: key, account: account, until: until, plan: 'year', signature: SchnorrSigner.fromSecret(rigSecret).sign(unsigned.digest));
  }

  final four = SimTable(
      humans: 4,
      seed: 3,
      crypto: crypto,
      id: newTableId(),
      keys: [for (var i = 0; i < 4; i++) SchnorrSigner.generate()],
      licenceOf: licenceOf);
  four.start();
  if (!four.run()) throw StateError('the game of four did not finish');
  keep('sealed_four', four, four.people.first.client, {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'});
  four.stop();

  final three = threeAndALeaver(crypto);
  keep('sealed_three_leave', three, three.people.first.client, threeNames);
  three.stop();
}

const threeNames = {0: 'Ada', 1: 'Bao', 2: 'Cy'};

/// Three people and a bot a juror holds; one person leaves in the second
/// trick, and the hand is finished with the seat's cards opened from
/// escrow. Played out and not stopped. Everything in it comes from fixed
/// seeds — the simulator's signers too — so the same library plays the
/// same record, byte for byte (test/kept_records_test.dart plays it again).
SimTable threeAndALeaver(DealCrypto crypto) {
  final three = SimTable(humans: 3, seed: 5, crypto: crypto, jurors: jurySize + 2, target: 1);
  three.start();
  final a = three.people.first.client;
  if (!three.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1, limitMs: 10 * 60 * 1000)) {
    throw StateError('the game of three did not reach play');
  }
  three.people[2].depart(Exit.leave);
  if (!three.clock.runUntil(() => a.done, limitMs: 30 * 60 * 1000)) throw StateError('the game of three did not finish: ${a.describe()}');
  three.clock.advance(20000);
  return three;
}
