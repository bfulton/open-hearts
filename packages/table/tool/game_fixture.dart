/// A finished sealed game's record, as a player's device sends it to be
/// kept (game_record.dart): four people, played out on the simulator.
/// For the browser suite's look at a kept game (e2e/flows.mjs).
///
///     cd packages/table && dart run tool/game_fixture.dart > game.json
library;

// A tool's output is what it prints.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

Future<void> main() async {
  await installNativeSchnorr();
  final crypto = await DealCrypto.load();
  // Real keys and a real table id: the browser checks it as a device
  // checks any kept game, and a simulator's fake signature passes only
  // where a simulator is running.
  final t = SimTable(humans: 4, seed: 3, crypto: crypto, id: newTableId(), keys: [for (var i = 0; i < 4; i++) SchnorrSigner.generate()]);
  t.start();
  if (!t.run()) throw StateError('the game did not finish');
  print(jsonEncode(GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'}).toJson()));
  t.stop();
}
