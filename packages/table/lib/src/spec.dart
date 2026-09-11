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
  const TableSpec({required this.id, required this.seed, required this.seats, this.rated = false});

  final String id;

  /// Whether the record counts for the players' ratings. A pool the
  /// player chose; carried in the table so every seat and the record
  /// agree.
  final bool rated;

  /// The deal's seed. Interim: every seat can compute every hand from
  /// it, which is why doc 03's deal replaces it before anything ships.
  final int seed;

  /// Seat order, four holders.
  final List<SeatHolder> seats;

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
