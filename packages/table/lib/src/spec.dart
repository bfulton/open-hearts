/// A table as agreed before the first card: who sits where, and the
/// seed the deal comes from until the verifiable deal replaces it.
library;

import 'package:engine/engine.dart';

import 'signing.dart';

sealed class SeatHolder {
  const SeatHolder();
}

class HumanSeat extends SeatHolder {
  const HumanSeat(this.key);
  final PublicKey key;
  @override
  String toString() => 'human ${key.substring(0, 6)}';
}

class BotSeat extends SeatHolder {
  const BotSeat(this.persona);
  final Persona persona;
  @override
  String toString() => 'bot ${persona.id}';
}

class TableSpec {
  const TableSpec(
      {required this.id, required this.seed, required this.seats, this.rated = false, this.sealed = false, this.target = gameOverScore});

  final String id;

  /// Whether the cards come from the verifiable deal (docs/03) rather
  /// than the seed: every hand shuffled by every seat with proofs, each
  /// person's cards known to them alone. Every live table; solo play
  /// and most of the simulator deal from the seed.
  final bool sealed;

  /// Whether the record counts for the players' ratings. A pool the
  /// player chose; carried in the table so every seat and the record
  /// agree.
  final bool rated;

  /// The score the game runs to. The player who starts the table
  /// chooses it; it rides in the signed start event because a table
  /// whose seats disagree about when the game ends forks at the end of
  /// a hand.
  final int target;

  /// The deal's seed at an unsealed table, where every seat can compute
  /// every hand from it; at a sealed one, the randomness of the jury
  /// draw and of the bots' public deal secrets.
  final int seed;

  /// Seat order, four holders.
  final List<SeatHolder> seats;

  /// The spec on the wire: a start event's shape, and a summons's.
  Map<String, Object?> toJson() => {
        'id': id,
        'seed': seed,
        'rated': rated,
        'sealed': sealed,
        'target': target,
        'seats': [
          for (final h in seats)
            switch (h) {
              HumanSeat(:final key) => {'key': key},
              BotSeat(:final persona) => {'bot': persona.id},
            },
        ],
      };

  /// Null for anything that is not a four-seat spec.
  static TableSpec? parse(Object? json) {
    try {
      final m = json as Map;
      final seats = <SeatHolder>[];
      for (final raw in m['seats'] as List) {
        final s = raw as Map;
        seats.add(s['bot'] is String ? BotSeat(Persona.named(s['bot'] as String)) : HumanSeat(s['key'] as String));
      }
      if (seats.length != seatCount) return null;
      return TableSpec(
          id: m['id'] as String,
          seed: m['seed'] as int,
          seats: seats,
          rated: m['rated'] == true,
          sealed: m['sealed'] == true,
          target: m['target'] as int? ?? gameOverScore);
    } catch (_) {
      return null;
    }
  }

  int? seatOf(PublicKey key) {
    for (var s = 0; s < seats.length; s++) {
      final h = seats[s];
      if (h is HumanSeat && h.key == key) return s;
    }
    return null;
  }

  /// The persona that takes over [seat] when its human leaves: fixed by
  /// the table, so every peer seats the same one.
  Persona replacementFor(int seat) {
    final n = Persona.roster.length;
    final base = id.codeUnits.fold(0, (a, b) => (a * 31 + b) % n);
    return Persona.roster[(base + seat) % n];
  }
}
