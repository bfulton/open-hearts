/// What a juror holding bot seats puts on the relay in a hand, in the
/// bytes a table event goes over the wire as. Run it when the deal's
/// proofs or the event bodies change, and carry the number to doc 04
/// ("Playing a seat nobody holds"):
///
///     dart run tool/juror_wire.dart
///
/// The proofs are the real ones; the simulator signs with a stand-in
/// half the length of a real signature, so every event is counted with
/// the difference added back.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

void main() async {
  final crypto = await DealCrypto.load();
  for (final humans in [2, 1]) {
    final t = SimTable(humans: humans, seed: 7, crypto: crypto, jurors: 4);
    t.start();
    final c = t.clients.first;
    final ok = t.clock.runUntil(() => c.game.handNumber >= 1, limitMs: 20 * 60 * 1000);
    final jurorKeys = {for (final j in t.jurors) j.signer.publicKey};
    final byKind = <String, List<int>>{};
    for (final d in c.record) {
      final e = d.event;
      if (!jurorKeys.contains(e.author)) continue;
      if (e.body['hand'] != 0) continue;
      // A real Schnorr signature is 128 hex characters where the
      // simulator's stand-in is 32.
      byKind.putIfAbsent(e.kind.name, () => []).add(jsonEncode(e.toJson()).length + 128 - FakeSigner.length);
    }
    var total = 0;
    print('--- $humans human(s), ${4 - humans} bot seat(s), hand 0 (reached: $ok) ---');
    final kinds = byKind.keys.toList()..sort();
    for (final k in kinds) {
      final v = byKind[k]!..sort();
      final sum = v.fold(0, (a, b) => a + b);
      total += sum;
      print('${k.padRight(14)} n=${v.length.toString().padLeft(3)}  '
          'min=${v.first}  max=${v.last}  total=$sum');
    }
    final seats = 4 - humans;
    print('every juror event of the hand: $total bytes, '
        '${(total / seats).round()} a bot seat');
    t.stop();
  }
}
