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
///     cd packages/table && OH_DEAL_MEMO=off dart run tool/kept_records.dart
library;

// A tool's output is what it prints.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:engine/engine.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

Future<void> main() async {
  await installNativeSchnorr();
  final crypto = await rememberedCrypto(kept: false);
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
  // audits, every one of them made by the library.
  final four = SimTable(humans: 4, seed: 3, crypto: crypto, id: newTableId(), keys: [for (var i = 0; i < 4; i++) SchnorrSigner.generate()]);
  four.start();
  if (!four.run()) throw StateError('the game of four did not finish');
  keep('sealed_four', four, four.people.first.client, {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'});
  four.stop();

  // Three people and a bot a juror holds; one person leaves in the
  // second trick, and the hand is finished with the seat's cards opened
  // from escrow.
  final three = SimTable(humans: 3, seed: 5, crypto: crypto, jurors: jurySize + 2, target: 1);
  three.start();
  final a = three.people.first.client;
  if (!three.clock.runUntil(() => a.game.phase == Phase.playing && a.game.tricksPlayed >= 1, limitMs: 10 * 60 * 1000)) {
    throw StateError('the game of three did not reach play');
  }
  three.people[2].depart(Exit.leave);
  if (!three.clock.runUntil(() => a.done, limitMs: 30 * 60 * 1000)) throw StateError('the game of three did not finish: ${a.describe()}');
  three.clock.advance(20000);
  keep('sealed_three_leave', three, a, {0: 'Ada', 1: 'Bao', 2: 'Cy'});
  three.stop();
}
