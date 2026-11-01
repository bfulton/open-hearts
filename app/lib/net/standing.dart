/// Ratings, as this device knows them: every result on the relays that
/// stands — the house's word on each game since the referee, and the
/// people's on each before — folded into a ledger, and this device's
/// account's line in it. A rating is an account's, whichever of its
/// devices played (packages/table, results.dart).
library;

import 'dart:async';

import 'package:table/table.dart';

import 'licence.dart' show houseKey;
import 'remote_config.dart' show waits;

/// The house whose results this build counts (licence.dart): none
/// counts in a build that names none.
PublicKey? get _house => RegExp(r'^[0-9a-f]{64}$').hasMatch(houseKey) ? houseKey : null;

class Standing {
  Standing(this.ledger, this.me);

  final Ledger ledger;

  /// This device's account.
  final String me;

  Rating get mine => ledger.of(me);

  /// Loads every result the relays hold and folds it. A few seconds on
  /// a busy relay; instant on an empty one. Each relay holds the
  /// results written to it, so the fold waits for all of them, within
  /// reason.
  static Future<Standing> load(List<Uri> relays, Signer signer, {required String account}) async {
    final t = RelayTransport(relays: relays, signer: signer, table: GameResult.tag);
    try {
      await t.ready.timeout(waits.standing);
      await t.allReady.timeout(waits.standingAll).catchError((_) {});
      return Standing(Ledger.from(t.lobbySoFar, house: _house, prior: botPrior), account);
    } finally {
      t.close();
    }
  }
}
