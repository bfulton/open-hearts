/// Ratings, as this device knows them: every result on the relay,
/// folded into a ledger, and this device's own line in it.
library;

import 'dart:math';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

class Standing {
  Standing(this.ledger, this.me);

  final Ledger ledger;
  final PublicKey me;

  Rating get mine => ledger.of(me);

  /// Loads every result the relay holds and folds it. A few seconds on
  /// a busy relay; instant on an empty one.
  static Future<Standing> load(Uri relay, Signer signer) async {
    final t = RelayTransport(url: relay, signer: signer, table: GameResult.tag);
    try {
      await t.ready.timeout(const Duration(seconds: 8));
      return Standing(Ledger.from(t.lobbySoFar), signer.publicKey);
    } finally {
      t.close();
    }
  }

  /// Publishes a finished game's result, signed by this device.
  static Future<void> publish(Uri relay, Signer signer, GameResult result) async {
    final t = RelayTransport(url: relay, signer: signer, table: GameResult.tag);
    try {
      await t.ready.timeout(const Duration(seconds: 8));
      t.announce(result.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      t.close();
    }
  }

  /// The bot to seat at a table of people rated about [rating]: the
  /// persona whose rating is nearest, ties broken by the draw.
  static Persona Function(int rating, int seat, Random random) botPicker(Ledger ledger) => (rating, seat, random) {
        final ranked = List.of(Persona.roster)..shuffle(random);
        ranked.sort((a, b) => (ledger.of(a.name).mu - rating).abs().compareTo((ledger.of(b.name).mu - rating).abs()));
        return ranked[seat % (ranked.length ~/ 2 + 1)];
      };
}
