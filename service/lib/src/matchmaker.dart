/// Seats strangers together.
///
/// Players who want a game say so on the relay every few seconds, in
/// the pool they chose — rated or unrated. Every five seconds the
/// matchmaker takes everyone waiting in a pool, in random order, and
/// seats them four to a table. Whoever is left over is put first in
/// the next round. Nobody waits long: once a player has been waiting
/// ten seconds without a full table, they get one, and bots take the
/// seats nobody came for.
///
/// The seating is one signed event per table, naming the seats; the
/// players build the same table from it and meet on its own tag.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

/// Someone waiting in a pool, as the matchmaker knows them.
class Waiting {
  Waiting({required this.key, required this.name, required this.since}) : lastSeen = since;

  final PublicKey key;
  final String name;

  /// When they were first seen waiting, ms.
  final int since;
  int lastSeen;

  /// Left over from an earlier round: seated first in the next.
  bool priority = false;

  @override
  String toString() => '${name.isEmpty ? key.substring(0, 6) : name}${priority ? '*' : ''}';
}

/// One round's decision.
class Plan {
  const Plan(this.tables, this.leftOver);

  /// Each a table's humans, one to four; bots fill the rest.
  final List<List<Waiting>> tables;

  /// Waiting on, with priority next time.
  final List<Waiting> leftOver;
}

/// The rule, on its own so it can be tested without a relay.
Plan plan(List<Waiting> waiting, {required int nowMs, required int botsAfterMs, required Random random}) {
  final first = waiting.where((w) => w.priority).toList()..shuffle(random);
  final rest = waiting.where((w) => !w.priority).toList()..shuffle(random);
  final order = [...first, ...rest];
  final tables = <List<Waiting>>[];
  var i = 0;
  for (; i + seatCount <= order.length; i += seatCount) {
    tables.add(order.sublist(i, i + seatCount));
  }
  final remainder = order.sublist(i);
  if (remainder.isNotEmpty && remainder.any((w) => nowMs - w.since >= botsAfterMs)) {
    // Somebody has waited long enough: the rest of them go with bots.
    tables.add(remainder);
    return Plan(tables, const []);
  }
  return Plan(tables, remainder);
}

class Matchmaker {
  Matchmaker({
    required this.relayUrl,
    Signer? signer,
    this.roundMs = 5000,
    this.botsAfterMs = 10000,
    this.staleMs = 12000,
    Random? random,
    this.log,
  })  : signer = signer ?? SchnorrSigner.generate(),
        _random = random ?? Random.secure();

  static const pools = ['rated', 'unrated'];

  /// The relay's tag for a pool's waiting room.
  static String poolTag(String pool) => 'queue:$pool';

  final Uri relayUrl;
  final Signer signer;
  final int roundMs;
  final int botsAfterMs;

  /// A player not heard from for this long has stopped waiting.
  final int staleMs;
  final Random _random;
  final void Function(String line)? log;

  final Map<String, RelayTransport> _pools = {};
  final Map<String, Map<PublicKey, Waiting>> _waiting = {for (final p in pools) p: {}};

  /// Players seated lately, and when: a waiting heartbeat that was in
  /// flight as they were seated must not put them in a second table.
  final Map<PublicKey, int> _seated = {};
  final List<StreamSubscription<NostrEvent>> _subs = [];
  Timer? _timer;
  int _tables = 0;

  int get tablesMade => _tables;

  Future<void> start() async {
    for (final pool in pools) {
      final t = RelayTransport(url: relayUrl, signer: signer, table: poolTag(pool));
      _pools[pool] = t;
      _subs.add(t.lobby.listen((e) => _onLobby(pool, e)));
    }
    await Future.wait(_pools.values.map((t) => t.ready));
    _timer = Timer.periodic(Duration(milliseconds: roundMs), (_) => _round());
    log?.call('matchmaker ${signer.publicKey.substring(0, 8)} on $relayUrl, a round every ${roundMs / 1000} s');
  }

  Future<void> close() async {
    _timer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    for (final t in _pools.values) {
      t.close();
    }
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void _onLobby(String pool, NostrEvent e) {
    if (e.kind != TableKinds.waiting) return;
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    if (c['kind'] != 'wait') return;
    final now = _now;
    final seatedAt = _seated[e.pubkey];
    if (seatedAt != null && now - seatedAt < staleMs) return;
    final w = _waiting[pool]!.putIfAbsent(e.pubkey, () {
      log?.call('$pool: ${c['name']} is waiting');
      return Waiting(key: e.pubkey, name: (c['name'] as String?)?.trim() ?? '', since: now);
    });
    w.lastSeen = now;
  }

  void _round() {
    final now = _now;
    for (final pool in pools) {
      final room = _waiting[pool]!;
      room.removeWhere((_, w) => now - w.lastSeen > staleMs);
      if (room.isEmpty) continue;
      final p = plan(room.values.toList(), nowMs: now, botsAfterMs: botsAfterMs, random: _random);
      for (final humans in p.tables) {
        _seat(pool, humans, now);
      }
      for (final w in p.leftOver) {
        w.priority = true;
      }
      if (p.tables.isNotEmpty || p.leftOver.isNotEmpty) {
        log?.call('$pool: ${p.tables.length} table(s), ${p.leftOver.length} waiting on');
      }
    }
  }

  void _seat(String pool, List<Waiting> humans, int now) {
    final id = 'm${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
    final seed = _random.nextInt(1 << 31);
    final draw = List.of(Persona.roster)..shuffle(Random(seed));
    final seats = <Map<String, Object?>>[];
    for (var s = 0; s < seatCount; s++) {
      if (s < humans.length) {
        seats.add({'key': humans[s].key, 'name': humans[s].name});
      } else {
        seats.add({'bot': draw[s].name});
      }
    }
    _pools[pool]!.announce({
      'kind': 'match',
      'table': id,
      'seed': seed,
      'rated': pool == 'rated',
      'seats': seats,
    });
    for (final w in humans) {
      _waiting[pool]!.remove(w.key);
      _seated[w.key] = now;
    }
    _seated.removeWhere((_, at) => now - at > 2 * staleMs);
    _tables++;
    log?.call('$pool: table $id — ${humans.join(', ')}${humans.length < seatCount ? ' and ${seatCount - humans.length} bot(s)' : ''}');
  }
}
