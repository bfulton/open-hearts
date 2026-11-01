/// A finished sealed game's record, as it is kept (record.dart): four
/// people, played out on the simulator with real keys, a salted table id
/// and a house of known key. For the browser suite's look at a kept
/// game (e2e/flows.mjs).
///
///     cd packages/table && dart run tool/game_fixture.dart > game.json
///
/// With `--unread`, a seated person has put three events the table does
/// not read in the log as the game goes (one of a kind no build knows,
/// two of a kind it knows with the body of none), as the referee takes
/// them. The house's word names a log that holds them (log.dart,
/// LogEntry.unread), and the record opens (kept_records_test.dart).
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

Future<void> main(List<String> args) async {
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
      salt: newSalt(),
      keys: [for (var i = 0; i < 4; i++) SchnorrSigner.generate()],
      houseKey: SchnorrSigner.fromSecret(rigHouseSecret),
      licenceOf: licenceOf);
  t.start();
  if (args.contains('--unread')) {
    // Three events from the second person, the second and third in the
    // middle of the game: each with its id the hash of its bytes and its
    // signature on the id, which is all the referee asks of an event.
    final liar = t.signers[1];
    final table = t.spec.id;
    t.clock.runUntil(() => t.referee.log.length > 8, limitMs: 10 * 60 * 1000);
    const body = {'at': 1};
    final id = digestOf(utf8.encode(jsonEncode([table, liar.publicKey, 'wave', body])));
    t.referee.receiveUnread({'id': id, 'table': table, 'author': liar.publicKey, 'kind': 'wave', 'body': body, 'sig': liar.sign(id)}, liar.publicKey);
    t.referee.receiveUnread(
        TableEvent.sign(liar, table: table, kind: EventKind.play, body: {'hand': 0, 'turn': TurnId.passTurns, 'seat': 1}).toJson(), liar.publicKey);
    t.clock.runUntil(() => t.referee.log.length > 12, limitMs: 10 * 60 * 1000);
    t.referee.receiveUnread(TableEvent.sign(liar, table: table, kind: EventKind.release, body: {'hand': 0}).toJson(), liar.publicKey);
  }
  if (!t.run()) throw StateError('the game did not finish');
  print(jsonEncode(GameRecord.of(t.people.first.client, names: {0: 'Ada', 1: 'Bao', 2: 'Cy', 3: 'Dee'}).toJson()));
  t.close();
}
