/// A table as agreed before the first card: who sits where, and the
/// seed an unsealed table's deal comes from.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:deal/deal.dart' show dealRevision;
import 'package:engine/engine.dart';

import 'licence.dart';
import 'signing.dart';
import 'timing.dart';

sealed class SeatHolder {
  const SeatHolder();
}

class HumanSeat extends SeatHolder {
  const HumanSeat(this.key, {this.licence});

  /// The device at the seat: the key that signs its every move.
  final PublicKey key;

  /// The service's word that [key] is one of an account's devices
  /// (licence.dart): what makes the seat the account's. Carried in the
  /// start event and so in the record, for anyone to check.
  final Licence? licence;

  /// Who sits here, for names, ratings and results: the account the
  /// licence names, or — where nothing is checked and none was given —
  /// the key itself, an account of one device.
  AccountId get account => licence?.account ?? key;

  @override
  String toString() => 'human ${key.substring(0, 6)}';
}

class BotSeat extends SeatHolder {
  const BotSeat(this.persona);
  final Persona persona;
  @override
  String toString() => 'bot ${persona.id}';
}

/// A table's salt ([TableSpec.salt]): 128 bits from the system's own
/// randomness, as 32 hex digits.
String newSalt([Random? random]) {
  final rng = random ?? Random.secure();
  // Sixteen bits at a time: a wider shift folds to zero in JavaScript.
  return List.generate(8, (_) => rng.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')).join();
}

/// The salt of a table the house seats in a pool (matching.dart,
/// PoolHost), in place of a drawn one: the first 128 bits of an
/// HMAC-SHA256, keyed by the house's own secret (house.dart,
/// House.secret), of everything else [spec] says. Nobody without the
/// secret can make it or guess it, so it hides the table's id as well
/// as [newSalt] does, and the house can tell a table it seated from its
/// spec alone, after a restart too.
String seatingSalt(List<int> secret, TableSpec spec) {
  final rest = spec.toJson()
    ..remove('id')
    ..remove('salt');
  return Hmac(sha256, secret).convert(utf8.encode('open-hearts/house/seating\n${jsonEncode(rest)}')).toString().substring(0, 32);
}

/// Whether [id] has a table id's shape: 32 hex digits.
bool validTableId(String id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id);

class TableSpec {
  TableSpec(
      {required this.seed,
      required this.seats,
      this.rated = false,
      this.sealed = false,
      this.target = gameOverScore,
      this.timing = TableTiming.standard,
      this.house,
      this.salt,
      int? deal})
      : deal = _revision(sealed, deal),
        id = idOf(_written(
            salt: salt, seed: seed, rated: rated, sealed: sealed, deal: _revision(sealed, deal), target: target, timing: timing, house: house, seats: seats));

  /// The revision a table says: this build's at a sealed table, where it
  /// matters; the first at any other, which says nothing of it.
  static int _revision(bool sealed, int? given) => sealed ? given ?? dealRevision : 1;

  /// A table kept before the referee, under the id it had then: one
  /// drawn at random, which nothing ties to the rest
  /// (legacy/v2_record.dart).
  TableSpec.kept(
      {required this.id,
      required this.seed,
      required this.seats,
      this.rated = false,
      this.sealed = false,
      this.target = gameOverScore,
      this.timing = TableTiming.standard})
      : house = null,
        salt = null,
        deal = 1;

  /// The table's id: the first 128 bits of the SHA-256 of everything
  /// else the spec says, as it is written ([toJson]), in 32 hex digits.
  ///
  /// It is the table's address — the tag its object on the relay is
  /// named by, and `/table/<id>` on play.openhearts.game — and it names
  /// this spec and no other. The log's first entry is a start saying
  /// the spec, from any one of its people, and the referee takes it only
  /// when the spec is the one the id names (service/do/referee.mjs), as
  /// every side does (rules.dart): so one person cannot start their
  /// table as anything but the table everybody was seated at.
  final String id;

  /// 128 bits, as 32 hex digits, from whoever seats the table: drawn
  /// ([newSalt]) by a device that starts one, and the house's
  /// [seatingSalt] at a table it seats in a pool. What keeps its id
  /// unguessable to somebody who knows everything else about it — the
  /// seats, which a pool publishes, and the options. None in a
  /// simulator's table.
  final String? salt;

  /// The revision of the deal's messages the table is played by
  /// ([dealRevision]), where its cards come from the verifiable deal.
  /// It is in the start, and in the id the start is taken by, because
  /// the log cannot say what a reader of it would take its messages for:
  /// a seat can say a message that is no pass by this revision and one
  /// by an earlier, and the table, which plays by this revision, takes
  /// the seat's next. A reader that took the earlier would take the
  /// first, and come to another game than the one that was played. A
  /// spec that says nothing of it is revision 1, as every game kept
  /// before 2 is.
  final int deal;

  /// Whether the cards come from the verifiable deal (docs/explanation/fair-deal.md) rather
  /// than the seed: every hand shuffled by every seat with proofs, each
  /// person's cards known to them alone. Every live table; solo play
  /// and most of the simulator deal from the seed.
  final bool sealed;

  /// Whether the record counts for the players' ratings. A pool the
  /// player chose; carried in the table so every seat and the record
  /// agree. The house serves a rated table only when its salt is the
  /// house's own ([seatingSalt]): only a pool's tables are rated.
  final bool rated;

  /// The score the game runs to: a pool's, which its tag names, or the
  /// one chosen by the player who starts a friends' table. It rides in
  /// the signed start event because a table whose seats disagree about
  /// when the game ends forks at the end of a hand.
  final int target;

  /// The table's clocks: a person's grace and bank, the house's
  /// deadlines, how long a closed connection is waited for
  /// (timing.dart). The house's at a pool's table, as the operator last
  /// told it, and at a friends' table those of the starting device's
  /// remote config. Carried in the start for the same reason as
  /// [target]: sides that disagreed about when a deadline passed would
  /// come to different tables.
  final TableTiming timing;

  /// The deal's seed at an unsealed table, where every seat can compute
  /// every hand from it; at a sealed one, the randomness of the public
  /// deal secret a seat takes when its person goes before its keys.
  final int seed;

  /// The house's key at a sealed table: the operator's service, which
  /// holds the bot seats and a piece of every person's escrow, and says
  /// how the game came out (docs/explanation/live-play.md). The key the
  /// build was made with; a table naming another is not sat at.
  final PublicKey? house;

  /// Seat order, four holders.
  final List<SeatHolder> seats;

  /// The spec on the wire, as the log's start carries it: its id, and
  /// what the id is the hash of.
  Map<String, Object?> toJson() => {
        'id': id,
        ..._written(salt: salt, seed: seed, rated: rated, sealed: sealed, deal: deal, target: target, timing: timing, house: house, seats: seats),
      };

  /// Everything a spec says but its id, as it is written.
  static Map<String, Object?> _written(
          {required String? salt,
          required int seed,
          required bool rated,
          required bool sealed,
          required int deal,
          required int target,
          required TableTiming timing,
          required PublicKey? house,
          required List<SeatHolder> seats}) =>
      {
        if (salt != null) 'salt': salt,
        'seed': seed,
        'rated': rated,
        'sealed': sealed,
        if (deal != 1) 'deal': deal,
        'target': target,
        'timing': timing.toJson(),
        if (house != null) 'house': house,
        'seats': [
          for (final h in seats)
            switch (h) {
              HumanSeat(:final key, :final licence) => {'key': key, if (licence != null) 'licence': licence.toJson()},
              BotSeat(:final persona) => {'bot': persona.id},
            },
        ],
      };

  /// The id of a spec that says [written], all but its id: the first
  /// 32 hex digits of the SHA-256 of its JSON. The referee works out the
  /// same from a start's text (service/do/referee.mjs, specIdOf).
  static String idOf(Map<String, Object?> written) => sha256.convert(utf8.encode(jsonEncode(written))).toString().substring(0, 32);

  /// Null for anything that is not a four-seat spec whose id is the one
  /// its fields name. [legacy] reads the spec of a game kept before the
  /// referee (legacy/v2_record.dart), whose id was drawn at random and
  /// whose clocks nothing checks any more, with whatever timing it says.
  static TableSpec? parse(Object? json, {bool legacy = false}) {
    try {
      final m = json as Map;
      final seats = <SeatHolder>[];
      for (final raw in m['seats'] as List) {
        final s = raw as Map;
        seats.add(s['bot'] is String
            ? BotSeat(Persona.named(s['bot'] as String))
            : HumanSeat(s['key'] as String, licence: s['licence'] == null ? null : Licence.parse(s['licence']) ?? (throw const FormatException('licence'))));
      }
      if (seats.length != seatCount) return null;
      if (legacy) {
        return TableSpec.kept(
            id: m['id'] as String,
            seed: m['seed'] as int,
            seats: seats,
            rated: m['rated'] == true,
            sealed: m['sealed'] == true,
            target: m['target'] as int? ?? gameOverScore,
            timing: TableTiming.parse(m['timing']));
      }
      final spec = TableSpec(
          seed: m['seed'] as int,
          seats: seats,
          rated: m['rated'] as bool,
          sealed: m['sealed'] as bool,
          deal: m['deal'] as int? ?? 1,
          target: m['target'] as int,
          timing: TableTiming.exactly(m['timing']) ?? (throw const FormatException('timing')),
          house: m['house'] as String?,
          salt: m['salt'] as String?);
      // Written as it says, or another spec than the one its id names.
      return spec.id == m['id'] && jsonEncode(spec.toJson()) == jsonEncode(m) ? spec : null;
    } catch (_) {
      return null;
    }
  }

  /// The accounts at the table, as they sat down.
  Set<AccountId> get accounts => {
        for (final h in seats)
          if (h is HumanSeat) h.account,
      };

  /// What is wrong with the seats' licences, or null when nothing is:
  /// every person's seat names its account with a licence the service
  /// signed for that very key ([licenceFits]) — given [at], one good
  /// then — and no account sits twice. A table that fails this is not
  /// sat at, not served and not believed (docs/explanation/live-play.md).
  /// Nothing is asked where accounts are not checked.
  String? licenceProblem({DateTime? at}) {
    final seen = <AccountId>{};
    for (var s = 0; s < seats.length; s++) {
      final h = seats[s];
      if (h is! HumanSeat) continue;
      if (!licenceFits(h.licence, h.key, at: at)) return 'seat $s has no licence for its key';
      if (!seen.add(h.account)) return 'seat $s is an account already seated';
    }
    return null;
  }

  /// The seat [account] sits in, by any of its devices.
  int? seatOfAccount(AccountId account) {
    for (var s = 0; s < seats.length; s++) {
      final h = seats[s];
      if (h is HumanSeat && h.account == account) return s;
    }
    return null;
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
