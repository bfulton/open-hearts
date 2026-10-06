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
  //
  // And each seat an account's, by a licence the browser rig's service
  // signed: BIP-340's published pair (e2e/build.sh, e2e/drive.mjs), whose
  // key the rig's build checks every seat by (licence.dart).
  const rigSecret = 'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
  Licence licenceOf(PublicKey key) {
    final account = key.substring(0, 32);
    final until = DateTime.utc(2099, 1, 1);
    final unsigned = Licence(key: key, account: account, until: until, plan: 'year', signature: '');
    return Licence(key: key, account: account, until: until, plan: 'year', signature: SchnorrSigner.fromSecret(rigSecret).sign(unsigned.digest));
  }

  final t = SimTable(
      humans: 4,
      seed: 3,
      crypto: crypto,
      id: newTableId(),
      keys: [for (var i = 0; i < 4; i++) SchnorrSigner.generate()],
      licenceOf: licenceOf);
  t.start();
  if (!t.run()) throw StateError('the game did not finish');
  print(jsonEncode(GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'}).toJson()));
  t.stop();
}
