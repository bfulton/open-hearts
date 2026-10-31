/// The bots a pool seats beside people (matching.dart, PoolHost), and
/// where a bot's rating starts: the house's to choose, by the ratings
/// as the results say them (results.dart, Ledger).
library;

import 'dart:math';

import 'package:engine/engine.dart';

import 'licence.dart' show validAccount;
import 'rating.dart';
import 'results.dart' show Ledger;

/// Where a bot with no results yet starts: its level's calibrated
/// rating. A person starts fresh.
Rating? botPrior(String id) {
  if (validAccount(id) || id.length == 64) return null; // an account, or a key
  try {
    return Rating(mu: Persona.priorRating(Persona.named(id).level).toDouble(), phi: 120);
  } catch (_) {
    return null;
  }
}

/// The bots to seat at a table of people rated about `rating`, by
/// [ledger]: personas at the levels nearest it, no name twice, ties
/// broken by the draw.
List<Persona> Function(int rating, int count, Random random) botsNear(Ledger ledger) => (rating, count, random) {
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
