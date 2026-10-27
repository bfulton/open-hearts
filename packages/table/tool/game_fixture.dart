/// A finished sealed game's record, as it is kept (record.dart): four
/// people, played out on the simulator with real keys, a real table id
/// and a house of known key. For the browser suite's look at a kept
/// game (e2e/flows.mjs).
///
///     cd packages/table && dart run tool/game_fixture.dart > game.json
library;

// A tool's output is what it prints.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

/// The house the browser rig's build plays with: BIP-340's third
/// published pair, a key known to everyone and so to nothing that
/// matters (e2e/build.sh).
const rigHouseSecret = 'c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9';

Future<void> main() async {
  await installNativeSchnorr();
  // Every proof made and checked, each once: four seats check the same
  // ones (package:deal/memo.dart).
  final crypto = await rememberedCrypto();
  // Each seat an account's, by a licence the browser rig's service
  // signed: BIP-340's second published pair (e2e/build.sh, e2e/drive.mjs),
  // whose key the rig's build checks every seat by (licence.dart).
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
      houseKey: SchnorrSigner.fromSecret(rigHouseSecret),
      licenceOf: licenceOf);
  t.start();
  if (!t.run()) throw StateError('the game did not finish');
  print(jsonEncode(GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'}).toJson()));
  t.close();
}
