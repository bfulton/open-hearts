/// A table as agreed before the first card: who sits where, and the
/// seed an unsealed table's deal comes from.
library;

import 'dart:math';

import 'package:engine/engine.dart';

import 'signing.dart';
import 'timing.dart';

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

/// A table's id: 128 bits from the system's own randomness, as 32 hex
/// digits. It is the table's address — the tag its object on the relay
/// is named by, and `/play/table/<id>` — so it is unguessable, and two
/// tables never share one.
String newTableId([Random? random]) {
  final rng = random ?? Random.secure();
  // Sixteen bits at a time: a wider shift folds to zero in JavaScript.
  return List.generate(8, (_) => rng.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')).join();
}

/// Whether [id] is one [newTableId] would make.
bool validTableId(String id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id);

class TableSpec {
  const TableSpec(
      {required this.id, required this.seed, required this.seats, this.rated = false, this.sealed = false, this.target = gameOverScore,
      this.timing = TableTiming.standard});

  final String id;

  /// Whether the cards come from the verifiable deal (docs/03-fair-deal.md) rather
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

  /// The table's clocks: a person's grace and bank, a held bot seat's
  /// deadlines, the silences and waits after which a seat proposes
  /// what the table then settles (timing.dart). Chosen like [target],
  /// by the device that starts the table from its remote config, and
  /// carried in the signed start event for the same reason: seats that
  /// disagree about when a boot is due back different sides of it.
  final TableTiming timing;

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
        // Left out at the standard, so that an ordinary table's spec
        // carries no timing at all.
        if (timing != TableTiming.standard) 'timing': timing.toJson(),
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
          target: m['target'] as int? ?? gameOverScore,
          timing: TableTiming.parse(m['timing']));
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
