/// Ratings, as this device knows them: every result on the relays that
/// stands — the house's word on each game since the referee, and the
/// people's on each before — folded into a ledger, and this device's
/// account's line in it. A rating is an account's, whichever of its
/// devices played (packages/table, results.dart).
library;

import 'dart:async';
import 'dart:math';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'licence.dart' show houseKey;
import 'relays.dart';
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
    final t = RelayTransport(relays: relays, signer: signer, table: GameResult.tag, pinned: pinnedRelays(relays));
    try {
      await t.ready.timeout(waits.standing);
      await t.allReady.timeout(waits.standingAll).catchError((_) {});
      return Standing(Ledger.from(t.lobbySoFar, house: _house, prior: prior), account);
    } finally {
      t.close();
    }
  }

  /// Where a bot with no results yet starts: its level's calibrated
  /// rating. A person starts fresh.
  static Rating? prior(String id) {
    if (validAccount(id) || id.length == 64) return null; // an account, or a key
    try {
      return Rating(mu: Persona.named(id).level.let(Persona.priorRating).toDouble(), phi: 120);
    } catch (_) {
      return null;
    }
  }

  /// The bots to seat at a table of people rated about `rating`:
  /// personas at the levels nearest it, no name twice, ties broken by
  /// the draw.
  static List<Persona> Function(int rating, int count, Random random) botPicker(Ledger ledger) => (rating, count, random) {
        final ranked = List.of(Persona.all)..shuffle(random);
        ranked.sort((a, b) => (ledger.of(a.id).mu - rating).abs().compareTo((ledger.of(b.id).mu - rating).abs()));
        final picked = <Persona>[];
        for (final p in ranked) {
          if (picked.any((x) => x.name == p.name)) continue;
          picked.add(p);
          if (picked.length == count) break;
        }
        return picked;
      };
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
