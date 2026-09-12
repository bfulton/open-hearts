/// Ratings, as this device knows them: every result on the relays,
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

  /// Loads every result the relays hold and folds it. A few seconds on
  /// a busy relay; instant on an empty one. Each relay holds the
  /// results written to it, so the fold waits for all of them, within
  /// reason.
  static Future<Standing> load(List<Uri> relays, Signer signer) async {
    final t = RelayTransport(relays: relays, signer: signer, table: GameResult.tag);
    try {
      await t.ready.timeout(const Duration(seconds: 8));
      await t.allReady.timeout(const Duration(seconds: 4)).catchError((_) {});
      return Standing(Ledger.from(t.lobbySoFar, prior: prior), signer.publicKey);
    } finally {
      t.close();
    }
  }

  /// Publishes a finished game's result, signed by this device.
  static Future<void> publish(List<Uri> relays, Signer signer, GameResult result) async {
    final t = RelayTransport(relays: relays, signer: signer, table: GameResult.tag);
    try {
      await t.ready.timeout(const Duration(seconds: 8));
      t.announce(result.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      t.close();
    }
  }

  /// Where a bot with no results yet starts: its level's calibrated
  /// rating. A person starts fresh.
  static Rating? prior(String id) {
    if (id.length == 64) return null; // a key
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
