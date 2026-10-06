/// Ratings, as this device knows them: every result on the relays,
/// folded into a ledger, and this device's account's line in it. A
/// rating is an account's, whichever of its devices played
/// (packages/table, results.dart).
library;

import 'dart:async';
import 'dart:math';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'relays.dart';
import 'remote_config.dart' show waits;

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
      return Standing(Ledger.from(t.lobbySoFar, prior: prior), account);
    } finally {
      t.close();
    }
  }

  /// Publishes a finished game's result, signed by this device, and
  /// waits for a relay to say it has it. A result stands only when a
  /// majority of the table's people published it — at a table of two,
  /// both (packages/table, results.dart) — so one that went nowhere
  /// costs the game its rating, and nobody would know. Tried again on a
  /// fresh connection after each of [retries]
  /// while no relay has taken it; true once one has.
  static Future<bool> publish(
    List<Uri> relays,
    Signer signer,
    GameResult result, {
    List<Duration> retries = const [Duration(seconds: 5), Duration(seconds: 20), Duration(minutes: 1)],
  }) async {
    for (var attempt = 0;; attempt++) {
      final t = RelayTransport(relays: relays, signer: signer, table: GameResult.tag, pinned: pinnedRelays(relays));
      try {
        await t.ready.timeout(waits.standing);
        if (await t.announceTaken(result.toJson())) return true;
      } on TimeoutException {
        // No relay answered at all: the same as none taking it.
      } finally {
        t.close();
      }
      if (attempt == retries.length) return false;
      await Future<void>.delayed(retries[attempt]);
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

  /// The bots to seat at a table of people rated about [rating]:
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
