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
/// seat is booted at its first turn and a bot takes it — the same
/// fifteen seconds as a friend who joined and closed the app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:engine/engine.dart';

import 'nostr.dart';
import 'relay_transport.dart';
import 'signing.dart';
import 'spec.dart';

/// Someone waiting, as the others see them.
class Waiter {
  Waiter({required this.key, required this.name, required this.rating, required this.since});

  final PublicKey key;
  final String name;

  /// Their rating, as they state it — it decides who they sit with,
  /// and nothing else, since the game's effect on ratings is computed
  /// from the record by everyone.
  final int rating;

  /// When they started waiting, ms since the epoch, by their own clock.
  final int since;

  /// When their last heartbeat arrived, ms.
  int lastSeen = 0;

  @override
  String toString() => '${name.isEmpty ? key.substring(0, 6) : name}($rating)';
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
    // The nearest three by rating, within the window.
    final near = order.where((w) => (w.rating - first.rating).abs() <= window).toList()
      ..sort((a, b) => (a.rating - first.rating).abs().compareTo((b.rating - first.rating).abs()));
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
      if (w != first && table.length < seatCount && (w.rating - first.rating).abs() <= windowPer * rounds) table.add(w);
    }
    for (final w in table) {
      left.remove(w);
    }
    tables.add(table);
  }
  return Plan(tables, left);
}

/// The relay's tag for a pool's waiting room.
String poolTag(String pool) => 'queue:$pool';

/// A player in a pool: says they are waiting, watches the others, hosts
/// when it is their turn to, and stops when seated.
class WaitingRoom {
  WaitingRoom({
    required this.relay,
    required this.pool,
    required this.name,
    required this.rating,
    this.roundMs = 5000,
    this.botsAfterMs = 10000,
    this.heartbeatMs = 2000,
    this.staleMs = 7000,
    int? nowMs,
    Random? random,
    this.log,
    this.botRating,
  }) : since = nowMs ?? DateTime.now().millisecondsSinceEpoch {
    _random = random ?? Random.secure();
    for (final e in List.of(relay.lobbySoFar)) {
      _onLobby(e);
    }
    _sub = relay.lobby.listen(_onLobby);
    _say();
    _timer = Timer.periodic(Duration(milliseconds: roundMs ~/ 20), (_) => _tick());
  }

  final RelayTransport relay;
  final String pool;
  final String name;
  final int rating;
  final int roundMs;
  final int botsAfterMs;
  final int heartbeatMs;

  /// A waiter not heard from for this long has gone.
  final int staleMs;
  final int since;
  final void Function(String line)? log;

  /// The rating a bot should be seated at, for a table of humans at
  /// [rating]: the host picks the persona nearest it. Null seats any.
  final Persona Function(int rating, int seat, Random random)? botRating;

  late final Random _random;
  final Map<PublicKey, Waiter> _others = {};
  final Set<int> _seatedRounds = {};
  int _lastSaid = 0;
  StreamSubscription<NostrEvent>? _sub;
  Timer? _timer;

  /// Set once seated.
  TableSpec? spec;
  Map<int, String> seatNames = const {};
  final _seated = StreamController<TableSpec>.broadcast();
  Stream<TableSpec> get seated => _seated.stream;

  /// Seatings that name this player, gathered for a moment before one
  /// is taken: two hosts with different views may both have seated
  /// them, and everyone takes the lowest table id.
  final List<(TableSpec, Map<int, String>)> _offers = [];
  Timer? _commit;

  PublicKey get me => relay.signer.publicKey;
  int get _now => DateTime.now().millisecondsSinceEpoch;
  int _roundOf(int ms) => ms ~/ roundMs;

  /// Everyone present, this player included, freshest first by key.
  List<Waiter> get present {
    final now = _now;
    final all = [
      Waiter(key: me, name: name, rating: rating, since: since)..lastSeen = now,
      ..._others.values.where((w) => now - w.lastSeen <= staleMs),
    ];
    all.sort((a, b) => a.key.compareTo(b.key));
    return all;
  }

  /// Who hosts the current round: the lowest key present.
  PublicKey get host => present.first.key;

  void _say() {
    if (spec != null) return;
    relay.announce({'kind': 'wait', 'name': name, 'rating': rating, 'since': since}, ephemeral: true);
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
      // Two halves: a 32-bit shift folds to zero when compiled to
      // JavaScript, where ints are doubles and shifts are 32-bit.
      final id = 'm${_random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')}'
          '${_random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')}';
      final seed = _random.nextInt(1 << 31);
      final draw = List.of(Persona.roster)..shuffle(Random(seed));
      final mean = humans.map((w) => w.rating).reduce((a, b) => a + b) ~/ humans.length;
      final seats = <Map<String, Object?>>[];
      for (var s = 0; s < seatCount; s++) {
        if (s < humans.length) {
          seats.add({'key': humans[s].key, 'name': humans[s].name});
        } else {
          final persona = botRating?.call(mean, s, Random(seed + s)) ?? draw[s];
          seats.add({'bot': persona.name});
        }
      }
      relay.announce({'kind': 'match', 'round': round, 'table': id, 'seed': seed, 'rated': pool == 'rated', 'seats': seats});
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
      case 'wait':
        if (e.kind != TableKinds.waiting || e.pubkey == me) return;
        final w = _others.putIfAbsent(
          e.pubkey,
          () => Waiter(
            key: e.pubkey,
            name: (c['name'] as String?)?.trim() ?? '',
            rating: c['rating'] as int? ?? 1500,
            since: c['since'] as int? ?? _now,
          ),
        );
        w.lastSeen = _now;
      case 'match':
        if (e.kind != TableKinds.lobby) return;
        final round = c['round'] as int?;
        if (round != null) _seatingsSeen[round] = (_seatingsSeen[round] ?? 0) + 1;
        _maybeSeated(c);
    }
  }

  void _maybeSeated(Map<String, Object?> c) {
    final seats = <SeatHolder>[];
    final names = <int, String>{};
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
          seats.add(HumanSeat(key));
          names[s] = m['name'] as String? ?? 'Someone';
        }
        s++;
      }
      if (!mine || seats.length != seatCount) return;
      _offers.add((TableSpec(id: c['table'] as String, seed: c['seed'] as int, seats: seats, rated: c['rated'] == true), names));
    } catch (_) {
      return;
    }
    _commit ??= Timer(Duration(milliseconds: roundMs ~/ 10), () {
      _offers.sort((a, b) => a.$1.id.compareTo(b.$1.id));
      spec = _offers.first.$1;
      seatNames = _offers.first.$2;
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
