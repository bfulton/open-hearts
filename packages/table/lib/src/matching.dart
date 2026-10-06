/// Seating strangers, with no one in charge.
///
/// Players who want a game say so on the relay every few seconds, in
/// the pool they chose — rated or unrated — with their rating and how
/// long they have waited. Everyone waiting sees everyone else. Time is
/// cut into rounds of five seconds, and in each round the lowest key
/// present acts as host: it runs [plan] over everyone it has heard
/// from and publishes the seating, one signed event per table naming
/// the seats, the same start event a friends' room uses. Everyone else
/// waits for a seating with their key in it. If the host says nothing
/// for a round, the next key steps in. A host can only waste five
/// seconds; it cannot forge a play, since every play is signed by its
/// seat and checked by every other.
///
/// Two hosts with different views may seat someone twice. They take
/// the seating with the lower table id, and the other table's empty
/// seat is booted at its first turn and a bot takes it, as for a
/// friend who joined and closed the app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:engine/engine.dart';

import 'licence.dart';
import 'nostr.dart';
import 'pace.dart';
import 'relay_transport.dart';
import 'signing.dart';
import 'spec.dart';
import 'timing.dart';

/// Someone waiting, as the others see them.
class Waiter {
  Waiter({required this.key, required this.name, required this.rating, required this.since, this.avatar, this.pace = 0, this.licence});

  final PublicKey key;
  final String name;

  /// The service's word that [key] is one of an account's devices
  /// (licence.dart), carried into the seating: a table is the
  /// accounts at it, and every seat checks every other's.
  final Licence? licence;

  /// Who is waiting: the account, or the key where nothing names one.
  AccountId get account => licence?.account ?? key;

  /// How they chose to look, as they said it — the app's business;
  /// the table carries it to the seating unread.
  final Map<String, Object?>? avatar;

  /// Their rating, as they state it — it decides who they sit with,
  /// and nothing else, since the game's effect on ratings is computed
  /// from the record by everyone.
  final int rating;

  /// Seconds they take over a card, as they state it — their own
  /// device's account of itself, since no two peers can agree on a
  /// number the record does not carry (pace.dart). Like the rating it
  /// decides who they sit with and nothing else. Zero is a player who
  /// has not played enough to know, and sits with anybody.
  final int pace;

  /// When they started waiting, ms since the epoch, by their own clock.
  final int since;

  /// When their last heartbeat arrived, ms.
  int lastSeen = 0;

  @override
  String toString() => '${name.isEmpty ? key.substring(0, 6) : name}($rating${pace == 0 ? '' : ', ${pace}s'})';
}

/// One round's decision.
class Plan {
  const Plan(this.tables, this.leftOver);

  /// Each a table's humans, one to four; bots fill the rest.
  final List<List<Waiter>> tables;

  /// Waiting on; first next time, by how long they have waited.
  final List<Waiter> leftOver;
}

/// The rule, on its own so it can be tested without a relay.
///
/// Whoever has waited through a round already is seated first, then
/// the rest, at random. A table is four players whose ratings lie
/// within a window of each other — [windowPer] points for every round
/// the first of them has waited, so a lonely rating widens its search
/// rather than waiting for ever. Once someone has waited [botsAfterMs],
/// the rest go with bots at their own rating.
Plan plan(
  List<Waiter> waiting, {
  required int nowMs,
  required int roundMs,
  required int botsAfterMs,
  required Random random,
  int windowPer = 100,
  int paceWindowPer = 3,
}) {
  final priority = waiting.where((w) => nowMs - w.since >= roundMs).toList()..shuffle(random);
  final rest = waiting.where((w) => nowMs - w.since < roundMs).toList()..shuffle(random);
  final order = [...priority, ...rest];
  final tables = <List<Waiter>>[];
  final left = <Waiter>[];
  while (order.isNotEmpty) {
    final first = order.removeAt(0);
    final rounds = (nowMs - first.since) ~/ roundMs + 1;
    final window = windowPer * rounds;
    // Both windows widen with every round waited, so a player alone in
    // a pool is never held out of a game by either of them. Pace is
    // the second of the two and the looser: it is about whether an
    // evening is pleasant, and a rating is about whether the game is.
    final paceWindow = paceWindowPer * rounds;
    // The nearest three by rating and then by pace, within both.
    final near = order
        .where((w) => (w.rating - first.rating).abs() <= window && paceApart(w.pace, first.pace) <= paceWindow)
        .toList()
      ..sort((a, b) {
        final byPace = paceApart(a.pace, first.pace).compareTo(paceApart(b.pace, first.pace));
        return byPace != 0 ? byPace : (a.rating - first.rating).abs().compareTo((b.rating - first.rating).abs());
      });
    if (near.length >= seatCount - 1) {
      final table = [first, ...near.take(seatCount - 1)];
      for (final w in table.skip(1)) {
        order.remove(w);
      }
      tables.add(table);
    } else {
      left.add(first);
    }
  }
  // Somebody has waited long enough: they go, with bots, and take with
  // them anyone left over within their window.
  final overdue = left.where((w) => nowMs - w.since >= botsAfterMs).toList();
  if (overdue.isNotEmpty) {
    final first = overdue.first;
    final rounds = (nowMs - first.since) ~/ roundMs + 1;
    final table = [first];
    for (final w in left) {
      if (w != first &&
          table.length < seatCount &&
          (w.rating - first.rating).abs() <= windowPer * rounds &&
          paceApart(w.pace, first.pace) <= paceWindowPer * rounds) {
        table.add(w);
      }
    }
    for (final w in table) {
      left.remove(w);
    }
    tables.add(table);
  }
  return Plan(tables, left);
}

/// The relay's tag for a pool's waiting room. The score the game runs
/// to is part of it, so that everyone who meets there wants the same
/// game; a game to fifty has the plain pool tag.
String poolTag(String pool, {int target = gameOverScore}) =>
    '${RelayTransport.poolPrefix}$pool${target == gameOverScore ? '' : ':$target'}';

/// A player in a pool: says they are waiting, watches the others, hosts
/// when it is their turn to, and stops when seated.
class WaitingRoom {
  WaitingRoom({
    required this.relay,
    required this.pool,
    required this.name,
    required this.rating,
    this.pace = 0,
    this.roundMs = 5000,
    this.botsAfterMs = 10000,
    this.heartbeatMs = 2000,
    this.staleMs = 7000,
    int? nowMs,
    Random? random,
    this.log,
    this.botRating,
    this.sealed = false,
    this.avatar,
    this.picture,
    this.target = gameOverScore,
    this.timing = TableTiming.standard,
    this.licence,
  }) : since = nowMs ?? DateTime.now().millisecondsSinceEpoch {
    _random = random ?? Random.secure();
    for (final e in List.of(relay.lobbySoFar)) {
      _onLobby(e);
    }
    _sub = relay.lobby.listen(_onLobby);
    _say();
    // A picture is heavy for a heartbeat: once, stored under the pool,
    // so whoever is seated with this player has it.
    if (picture != null) relay.announce({'kind': 'picture', 'jpeg': picture});
    _timer = Timer.periodic(Duration(milliseconds: roundMs ~/ 20), (_) => _tick());
  }

  final RelayTransport relay;
  final String pool;
  final String name;

  /// The score the tables this player sits at run to: it seats nobody
  /// who asked for another, and the tables it hosts say so.
  final int target;

  /// The clocks of the tables this player hosts (timing.dart), from
  /// its remote config. Only the host's counts: it rides in the
  /// seating, and every seat takes it from there.
  final TableTiming timing;

  /// Whether this device deals sealed tables (docs/03-fair-deal.md): the tables it
  /// seats are sealed, and it sits only at sealed ones.
  final bool sealed;
  final int rating;

  /// Seconds this device takes over a card, as it measured itself
  /// (pace.dart); zero until it has played enough to know.
  final int pace;

  /// How this player looks, for the others: carried in every
  /// heartbeat and into the seating. Null for nothing chosen.
  final Map<String, Object?>? avatar;

  /// A picture of this player, base64, sent once; null for none.
  final String? picture;

  /// This device's licence, said with every heartbeat and carried into
  /// every seating it is in. Where accounts are checked (licence.dart)
  /// a waiter without one is not seated by anyone.
  final Licence? licence;
  final int roundMs;
  final int botsAfterMs;
  final int heartbeatMs;

  /// A waiter not heard from for this long has gone.
  final int staleMs;
  final int since;
  final void Function(String line)? log;

  /// The bots for a table of people rated about [rating], [count] of
  /// them, no persona twice. Null seats the roster at the top.
  final List<Persona> Function(int rating, int count, Random random)? botRating;

  late final Random _random;
  final Map<PublicKey, Waiter> _others = {};
  final Set<int> _seatedRounds = {};
  int _lastSaid = 0;
  StreamSubscription<NostrEvent>? _sub;
  Timer? _timer;

  /// Set once seated.
  TableSpec? spec;
  Map<int, String> seatNames = const {};

  /// Seat number to how that human looks, as the seating carried it.
  Map<int, Map<String, Object?>> seatAvatars = const {};

  /// Pictures by key, base64, from the events that carried them.
  final Map<PublicKey, String> pictures = {};
  final _seated = StreamController<TableSpec>.broadcast();
  Stream<TableSpec> get seated => _seated.stream;

  /// Seatings that name this player, gathered for a moment before one
  /// is taken: two hosts with different views may both have seated
  /// them, and everyone takes the lowest table id.
  final List<(TableSpec, Map<int, String>, Map<int, Map<String, Object?>>)> _offers = [];
  Timer? _commit;

  PublicKey get me => relay.signer.publicKey;
  int get _now => DateTime.now().millisecondsSinceEpoch;
  int _roundOf(int ms) => ms ~/ roundMs;

  /// Everyone present, this player included, freshest first by key.
  List<Waiter> get present {
    final now = _now;
    final all = [
      Waiter(key: me, name: name, rating: rating, since: since, avatar: avatar, licence: licence)..lastSeen = now,
      ..._others.values.where((w) => now - w.lastSeen <= staleMs),
    ];
    all.sort((a, b) => a.key.compareTo(b.key));
    return all;
  }

  /// Who hosts the current round: the lowest key present.
  PublicKey get host => present.first.key;

  void _say() {
    if (spec != null) return;
    relay.announce(
        {
          'kind': 'wait',
          'name': name,
          'rating': rating,
          if (pace > 0) 'pace': pace,
          'since': since,
          if (avatar != null) 'avatar': avatar,
          if (licence != null) 'licence': licence!.toJson(),
        },
        ephemeral: true);
    _lastSaid = _now;
  }

  void _tick() {
    if (spec != null) return;
    final now = _now;
    if (now - _lastSaid >= heartbeatMs) _say();
    final round = _roundOf(now);
    final into = now - round * roundMs;
    final ranked = present.map((w) => w.key).toList();
    final mine = ranked.indexOf(me);
    // The host acts a fifth of the way into the round, when the
    // heartbeats have settled; the next in line a fifth later if nothing
    // was seated, and so on down.
    final myTurnAt = (roundMs ~/ 5) * (1 + mine);
    if (into >= myTurnAt && !_seatedRounds.contains(round) && !_anySeating(round)) {
      _seatedRounds.add(round);
      _hostRound(round, now);
    }
  }

  final Map<int, int> _seatingsSeen = {};
  bool _anySeating(int round) => (_seatingsSeen[round] ?? 0) > 0;

  void _hostRound(int round, int now) {
    final all = present;
    final p = plan(all, nowMs: now, roundMs: roundMs, botsAfterMs: botsAfterMs, random: Random(round));
    if (p.tables.isEmpty) return;
    log?.call('$pool round $round: hosting, ${all.length} present, ${p.tables.length} table(s)');
    for (final humans in p.tables) {
      final id = newTableId(_random);
      final seed = _random.nextInt(1 << 31);
      final mean = humans.map((w) => w.rating).reduce((a, b) => a + b) ~/ humans.length;
      final wanted = seatCount - humans.length;
      final bots = botRating?.call(mean, wanted, Random(seed)) ?? (List.of(Persona.roster)..shuffle(Random(seed))).take(wanted).toList();
      final seats = <Map<String, Object?>>[];
      for (var s = 0; s < seatCount; s++) {
        if (s < humans.length) {
          seats.add({
            'key': humans[s].key,
            'name': humans[s].name,
            if (humans[s].avatar != null) 'avatar': humans[s].avatar,
            if (humans[s].licence != null) 'licence': humans[s].licence!.toJson(),
          });
        } else {
          seats.add({'bot': bots[s - humans.length].id});
        }
      }
      relay.announce({
        'kind': 'match',
        'round': round,
        'table': id,
        'seed': seed,
        'rated': pool == 'rated',
        'sealed': sealed,
        'target': target,
        'timing': timing.toJson(),
        'seats': seats,
        'policy': botPolicyVersion,
      });
    }
  }

  void _onLobby(NostrEvent e) {
    if (spec != null) return;
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    switch (c['kind']) {
      case 'picture':
        if (e.kind != TableKinds.lobby) return;
        final jpeg = c['jpeg'];
        if (jpeg is String && jpeg.length <= 20000) pictures[e.pubkey] = jpeg;
      case 'wait':
        if (e.kind != TableKinds.waiting || e.pubkey == me) return;
        // A waiter is seated only with the service's word that its key
        // is an account's device — and never beside this device's own
        // account, which is one person on two devices.
        final licence = Licence.parse(c['licence']);
        if (!licenceFits(licence, e.pubkey, at: DateTime.fromMillisecondsSinceEpoch(_now))) return;
        if (licence != null && licence.account == this.licence?.account) return;
        final w = _others.putIfAbsent(
          e.pubkey,
          () => Waiter(
            key: e.pubkey,
            name: (c['name'] as String?)?.trim() ?? '',
            rating: c['rating'] as int? ?? 1500,
            pace: switch (c['pace']) { final int p when p > 0 && p <= 120 => p, _ => 0 },
            since: c['since'] as int? ?? _now,
            avatar: c['avatar'] is Map ? Map<String, Object?>.from(c['avatar'] as Map) : null,
            licence: licence,
          ),
        );
        w.lastSeen = _now;
      case 'match':
        if (e.kind != TableKinds.lobby) return;
        final round = c['round'] as int?;
        // A seating is for the round that made it and no other. It
        // goes out on the stored kind, so that a device arriving at a
        // room code is handed the room announced before it got there
        // (nostr.dart); a pool is subscribed to the same way and with
        // no window on it, so a relay hands a device that comes back
        // to the pool every seating it has ever carried there — this
        // device's own from a game an hour ago among them, at a table
        // whose people have long closed their apps.
        //
        // A round or two either side, and no more. Rounds are a
        // shared clock bucket and everything else here compares them
        // exactly — the host acts a fifth of the way into its own
        // round, and a seating is counted against the round it names
        // — so a device whose clock is further out than that is one
        // that could not have been seated anyway.
        if (round == null || (round - _roundOf(_now)).abs() > 2) return;
        _seatingsSeen[round] = (_seatingsSeen[round] ?? 0) + 1;
        _maybeSeated(c);
    }
  }

  void _maybeSeated(Map<String, Object?> c) {
    // A table whose host computes the bots by another version of the
    // policy would fork on the first bot's card: not one to sit at.
    if (c['policy'] != botPolicyVersion) return;
    // A device that cannot run the deal cannot sit at a sealed table,
    // and one that can does not sit at an unsealed one.
    if ((c['sealed'] == true) != sealed) return;
    // A host on an older build says nothing about the target, which
    // means the game it seats runs to fifty.
    if ((c['target'] as int? ?? gameOverScore) != target) return;
    final seats = <SeatHolder>[];
    final names = <int, String>{};
    final avatars = <int, Map<String, Object?>>{};
    var mine = false;
    var s = 0;
    try {
      for (final raw in c['seats'] as List) {
        final m = Map<String, Object?>.from(raw as Map);
        if (m['bot'] is String) {
          seats.add(BotSeat(Persona.named(m['bot'] as String)));
        } else {
          final key = m['key'] as String;
          if (key == me) mine = true;
          seats.add(HumanSeat(key, licence: m['licence'] == null ? null : Licence.parse(m['licence']) ?? (throw const FormatException('licence'))));
          names[s] = m['name'] as String? ?? 'Someone';
          if (m['avatar'] is Map) avatars[s] = Map<String, Object?>.from(m['avatar'] as Map);
        }
        s++;
      }
      // A table is named by its id, and its id is its address: one that
      // could be guessed, or shared with another table, is not taken.
      if (!mine || seats.length != seatCount || c['table'] is! String || !validTableId(c['table'] as String)) return;
      final offered = TableSpec(
            id: c['table'] as String,
            seed: c['seed'] as int,
            seats: seats,
            rated: c['rated'] == true,
            sealed: c['sealed'] == true,
            target: target,
            // The host's clocks, not this device's; a host on an older
            // build says none, which is the standard table.
            timing: TableTiming.parse(c['timing']));
      // Every seat an account's, by the service's word, and each
      // account once: a seating that is not is no table to sit at.
      final wrong = offered.licenceProblem(at: DateTime.fromMillisecondsSinceEpoch(_now));
      if (wrong != null) {
        log?.call('$pool: a seating refused: $wrong');
        return;
      }
      _offers.add((offered, names, avatars));
    } catch (_) {
      return;
    }
    _commit ??= Timer(Duration(milliseconds: roundMs ~/ 10), () {
      _offers.sort((a, b) => a.$1.id.compareTo(b.$1.id));
      spec = _offers.first.$1;
      seatNames = _offers.first.$2;
      seatAvatars = _offers.first.$3;
      log?.call('$pool: seated at ${spec!.id}${_offers.length > 1 ? ' (of ${_offers.length} offers)' : ''}');
      _timer?.cancel();
      _seated.add(spec!);
    });
  }

  void close() {
    _timer?.cancel();
    _commit?.cancel();
    _sub?.cancel();
    _seated.close();
  }
}
