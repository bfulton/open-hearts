/// Seating strangers: the house seats every pool.
///
/// Players who want a game say so on the relay every couple of seconds
/// ([WaitingRoom]), in the pool they chose — rated or unrated, and the
/// score the game runs to — with their rating, their pace and how long
/// they have waited. The house hears everyone in a pool ([PoolHost]):
/// the pool's object on the relay wakes it while anybody is waiting
/// there (service/do/pool.mjs). Time is cut into rounds of five
/// seconds, and in each the house runs [plan] over everyone it hears
/// and publishes the seating, one event per table naming the seats,
/// signed by its key. A device takes a seating from its build's house
/// and nobody else, and the relay carries a pool's seating from nobody
/// else either.
///
/// So one hand seats a pool, and it seats each player once: whoever a
/// seating names is out of the pool as it is said, and nobody is seated
/// at two tables, or parted from the people seated with them. Every
/// table a pool seats is sealed and has the house at it anyway
/// (docs/explanation/live-play.md), so a pool asks nothing of the house
/// that its tables did not.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:engine/engine.dart';

import 'licence.dart';
import 'names.dart';
import 'nostr.dart';
import 'pace.dart';
import 'relay_transport.dart';
import 'signing.dart';
import 'spec.dart';
import 'timing.dart';

/// Someone waiting, as the others see them.
class Waiter {
  Waiter({required this.key, required this.name, required this.rating, required this.since, this.avatar, this.pace = 0, this.licence, this.botsAfterMs});

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

  /// When they started waiting, ms since the epoch: by their own clock
  /// as their own device has it ([WaitingRoom.since]), and by the
  /// house's, from when it first heard them, as the house seats them
  /// ([PoolHost]) — a device's clock is its own, and may be out by
  /// minutes.
  final int since;

  /// How long they will wait for people before bots fill the seats, as
  /// they last said it ([WaitingRoom.waitForPerson], [WaitingRoom.playWithBots]);
  /// null for the pool's own.
  int? botsAfterMs;

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
/// rather than waiting for ever. Once someone has waited as long as
/// they said they would before bots ([Waiter.botsAfterMs]; the pool's
/// [botsAfterMs] for one who said nothing), they go with bots at their
/// own rating.
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
  final overdue = left.where((w) => nowMs - w.since >= (w.botsAfterMs ?? botsAfterMs)).toList();
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

/// The pool and the score a pool's tag names ([poolTag]): one of the
/// [pools], and a score no higher than the long game's, or null for a
/// tag that is not a pool's. The app offers the game and the long game
/// (app/lib/game_options.dart); a driven build asks for as little as a
/// point (app/lib/net/address.dart, targetIn).
({String pool, int target})? poolOf(String tag) {
  if (!tag.startsWith(RelayTransport.poolPrefix)) return null;
  final parts = tag.substring(RelayTransport.poolPrefix.length).split(':');
  if (parts.length > 2 || !pools.contains(parts.first)) return null;
  final target = parts.length == 1 ? gameOverScore : int.tryParse(parts[1]);
  if (target == null || target < 1 || target > longGameScore) return null;
  // One tag a pool: the default score is the plain tag's, never named,
  // and a score is said one way.
  if (poolTag(parts.first, target: target) != tag) return null;
  return (pool: parts.first, target: target);
}

/// The pools there are: a rated game, and one that is not.
const pools = ['rated', 'unrated'];

/// How long a pool's round is: the house seats a pool once a round
/// ([PoolHost]), and a seating says which round it was.
const poolRoundMs = 5000;

/// How long someone waiting goes unheard before they are taken to have
/// gone: a few of their heartbeats ([WaitingRoom.heartbeatMs]).
const poolStaleMs = 7000;

/// A player in a pool: says they are waiting, watches the others, and
/// takes the first seating the house names them in.
class WaitingRoom {
  WaitingRoom({
    required this.relay,
    required this.pool,
    required this.name,
    required this.rating,
    required this.house,
    this.pace = 0,
    this.roundMs = poolRoundMs,
    int botsAfterMs = defaultBotsAfterMs,
    this.heartbeatMs = 2000,
    this.staleMs = poolStaleMs,
    int? nowMs,
    this.log,
    this.avatar,
    this.picture,
    this.target = gameOverScore,
    this.licence,
  })  : poolBotsAfterMs = botsAfterMs,
        botsAfterMs = botsAfterMs,
        since = nowMs ?? DateTime.now().millisecondsSinceEpoch {
    for (final e in List.of(relay.lobbySoFar)) {
      _onLobby(e);
    }
    _sub = relay.lobby.listen(_onLobby);
    _say();
    // A picture is heavy for a heartbeat: once, stored under the pool,
    // so whoever is seated with this player has it.
    if (picture != null) relay.announce({'kind': 'picture', 'jpeg': picture});
    _timer = Timer.periodic(Duration(milliseconds: heartbeatMs ~/ 4), (_) => _tick());
  }

  final RelayTransport relay;
  final String pool;
  final String name;

  /// The score the tables this player sits at run to: it is seated in
  /// that game's pool, and sits at no table of another.
  final int target;

  /// The house this build plays with (docs/explanation/live-play.md):
  /// the one key a seating is taken from, and the one a table it seats
  /// names. A room with none is seated by nobody.
  final PublicKey? house;
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
  /// a waiter without one is not seated.
  final Licence? licence;

  /// The house's round ([poolRoundMs]): a seating says the round it
  /// was made in, and is for that round and no other.
  final int roundMs;

  /// The pool's wait before bots: what every waiter who has said
  /// nothing else gets.
  final int poolBotsAfterMs;

  /// How long this player waits for people before bots fill the empty
  /// seats: [poolBotsAfterMs], unless they chose otherwise
  /// ([waitForPerson], [playWithBots]).
  int botsAfterMs;
  final int heartbeatMs;

  /// The pool's wait before bots, unless the room is given another.
  static const defaultBotsAfterMs = 10000;

  /// The longest anyone waits for a person: then bots, as for everyone.
  static const personAtMostMs = 5 * 60 * 1000;

  /// Waits up to [personAtMostMs] for people rather than the pool's ten
  /// seconds, and says so at once.
  void waitForPerson() {
    botsAfterMs = personAtMostMs;
    _say();
  }

  /// Takes bots for the empty seats at the next round, and says so at
  /// once.
  void playWithBots() {
    botsAfterMs = 0;
    _say();
  }

  /// A waiter not heard from for this long has gone.
  final int staleMs;
  final int since;
  final void Function(String line)? log;

  final Map<PublicKey, Waiter> _others = {};

  /// Whom a seating took out of the pool: waiting no longer.
  late final _Seated _gone = _Seated(staleMs);
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

  PublicKey get me => relay.signer.publicKey;
  int get _now => DateTime.now().millisecondsSinceEpoch;
  int _roundOf(int ms) => ms ~/ roundMs;

  /// Everyone waiting, as far as this device can tell, itself included,
  /// by key: who it has heard lately and has not seen seated.
  List<Waiter> get present {
    final now = _now;
    final all = [
      Waiter(key: me, name: name, rating: rating, since: since, avatar: avatar, pace: pace, licence: licence, botsAfterMs: botsAfterMs)
        ..lastSeen = now,
      ..._others.values.where((w) => now - w.lastSeen <= staleMs),
    ];
    all.sort((a, b) => a.key.compareTo(b.key));
    return all;
  }

  void _say() {
    if (spec != null) return;
    relay.announce(
        {
          'kind': 'wait',
          'name': name,
          'rating': rating,
          if (pace > 0) 'pace': pace,
          if (botsAfterMs != poolBotsAfterMs) 'botsAfter': botsAfterMs,
          'since': since,
          if (avatar != null) 'avatar': avatar,
          if (licence != null) 'licence': licence!.toJson(),
        },
        ephemeral: true);
    _lastSaid = _now;
  }

  void _tick() {
    if (spec != null) return;
    _gone.prune(_now);
    if (_now - _lastSaid >= heartbeatMs) _say();
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
        if (e.kind != TableKinds.waiting || e.pubkey == me || _gone.hides(e.pubkey, _now)) return;
        // Whom the screen counts as waiting: whoever the service's word
        // says is an account's device, and not this device's own
        // account, which is one person on two devices.
        final licence = Licence.parse(c['licence']);
        if (!licenceFits(licence, e.pubkey, at: DateTime.fromMillisecondsSinceEpoch(_now))) return;
        if (licence != null && licence.account == this.licence?.account) return;
        final w = _others.putIfAbsent(
          e.pubkey,
          () => Waiter(
            key: e.pubkey,
            name: cleanName(c['name'] as String? ?? ''),
            rating: c['rating'] as int? ?? 1500,
            pace: switch (c['pace']) { final int p when p > 0 && p <= 120 => p, _ => 0 },
            since: c['since'] as int? ?? _now,
            avatar: c['avatar'] is Map ? Map<String, Object?>.from(c['avatar'] as Map) : null,
            licence: licence,
          ),
        );
        w.lastSeen = _now;
      case 'match':
        // The house's, or no seating at all.
        if (e.kind != TableKinds.lobby || house == null || e.pubkey != house) return;
        final round = c['round'] as int?;
        // A seating is for the round that made it and no other. It goes
        // out on the stored kind, so that a device arriving at a room
        // code is handed the room announced before it got there
        // (nostr.dart); a pool is subscribed to the same way, so a relay
        // hands a device that comes back to the pool the seatings of the
        // last minute (RelayTransport.poolHistorySeconds) — this device's
        // own from its last game among them, at a table whose people
        // have closed their apps.
        //
        // A round or two either side of this device's clock, and no
        // more: the round is the house's, by its clock, and a device
        // further out than that is one that could not tell a seating of
        // now from one of a minute ago.
        if (round == null || (round - _roundOf(_now)).abs() > 2) return;
        _maybeSeated(c);
        // Whoever it seated is waiting no longer, whether or not this
        // device was among them.
        if (c['seats'] case final List<Object?> seats) {
          for (final s in seats) {
            if (s case {'key': final String key}) {
              _others.remove(key);
              _gone.add(key, _now);
            }
          }
        }
    }
  }

  void _maybeSeated(Map<String, Object?> c) {
    // A table whose house computes the bots by another version of the
    // policy would fork on the first bot's card: not one to sit at.
    if (c['policy'] != botPolicyVersion) return;
    // Every table a pool seats is sealed, and the house's to hold the
    // bots of and to say the end of: this build's.
    if (c['sealed'] != true || c['house'] != house) return;
    // Another pool's game.
    if (c['target'] != target) return;
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
          names[s] = cleanName(m['name'] as String? ?? 'Someone');
          if (m['avatar'] is Map) avatars[s] = Map<String, Object?>.from(m['avatar'] as Map);
        }
        s++;
      }
      if (!mine || seats.length != seatCount) return;
      final offered = TableSpec(
          seed: c['seed'] as int,
          seats: seats,
          rated: c['rated'] == true,
          sealed: true,
          target: target,
          // The house's clocks, said in full (TableTiming.exactly): a
          // seating without them is no table.
          timing: TableTiming.exactly(c['timing']) ?? (throw const FormatException('timing')),
          house: house,
          salt: c['salt'] as String? ?? (throw const FormatException('salt')));
      // A table is named by its id, which is its spec's: a seating whose
      // table is not the one it says is no table, and one with no salt
      // has an id anybody who saw the seats could work out.
      if (c['table'] != offered.id || !validTableId(offered.salt!)) {
        log?.call('$pool: a seating refused: its table is not its spec\'s');
        return;
      }
      // Every seat an account's, by the service's word, and each
      // account once: a seating that is not is no table to sit at.
      final wrong = offered.licenceProblem(at: DateTime.fromMillisecondsSinceEpoch(_now));
      if (wrong != null) {
        log?.call('$pool: a seating refused: $wrong');
        return;
      }
      spec = offered;
      seatNames = names;
      seatAvatars = avatars;
    } catch (_) {
      return;
    }
    log?.call('$pool: seated at ${spec!.id}');
    _timer?.cancel();
    _seated.add(spec!);
  }

  void close() {
    _timer?.cancel();
    _sub?.cancel();
    _seated.close();
  }
}

/// The house's side of a pool ([poolTag]): hears everyone waiting there,
/// seats them a round at a time, and is done once nobody has waited
/// there for [idleMs].
///
/// [relay] is the pool's tag, signed as the house: what it seats names
/// [relay]'s key as its house. Whoever a seating names is out of the
/// pool as it is said: what they say after is not heard for [staleMs],
/// which is longer than any heartbeat they sent before it reached them
/// takes to arrive. A device that never took the seating is still
/// saying it waits after that, and is heard again.
class PoolHost {
  PoolHost({
    required this.relay,
    required this.pool,
    required this.bots,
    required this.secret,
    this.target = gameOverScore,
    this.timing = TableTiming.standard,
    this.roundMs = poolRoundMs,
    this.staleMs = poolStaleMs,
    this.botsAfterMs = WaitingRoom.defaultBotsAfterMs,
    this.idleMs = 60000,
    Future<void>? ready,
    Random? random,
    this.log,
    this.onIdle,
  }) : _heardAt = DateTime.now().millisecondsSinceEpoch {
    _random = random ?? Random.secure();
    if (ready == null) {
      _ready = true;
    } else {
      // Nothing seated before what it waits on, and nothing for ever
      // waited on: the bots are chosen by ratings it may still be
      // reading.
      unawaited(ready.whenComplete(() => _ready = true).catchError((_) {}));
    }
    for (final e in List.of(relay.lobbySoFar)) {
      _onLobby(e);
    }
    _sub = relay.lobby.listen(_onLobby);
    _timer = Timer.periodic(Duration(milliseconds: roundMs ~/ 20), (_) => _tick());
  }

  final RelayTransport relay;
  final String pool;

  /// The house's own secret (house.dart, House.secret): every table this
  /// pool seats is salted with it ([seatingSalt]), which is how the
  /// house knows a rated table for one it seated.
  final Uint8List secret;

  /// The score the games this pool seats run to.
  final int target;

  /// The clocks of the tables it seats (timing.dart): the operator's, as
  /// the house was last told them (service/do/bench.mjs). A change is
  /// the next seating's.
  TableTiming timing;

  /// The bots for a table of people rated about `rating`, `count` of
  /// them, no persona twice (bots.dart, botsNear).
  final List<Persona> Function(int rating, int count, Random random) bots;

  final int roundMs;

  /// How long someone waiting goes unheard before they are taken to
  /// have gone, and how long someone seated is not heard.
  final int staleMs;

  /// The pool's wait before bots, for whoever has said nothing else.
  final int botsAfterMs;

  /// How long with nobody heard waiting before this pool is left
  /// ([onIdle]).
  final int idleMs;

  final void Function(String line)? log;

  /// Told once nobody has waited in the pool for [idleMs].
  final void Function()? onIdle;

  late final Random _random;
  final Map<PublicKey, Waiter> _waiting = {};

  /// Whom this house seated: not heard for [staleMs] after.
  late final _Seated _seated = _Seated(staleMs);
  bool _ready = false;
  int _hosted = -1;
  int _heardAt;
  bool _idle = false;
  StreamSubscription<NostrEvent>? _sub;
  Timer? _timer;

  /// The house's key, which every table it seats names.
  PublicKey get house => relay.signer.publicKey;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Everyone waiting now, as the house hears them, by key.
  List<Waiter> get present {
    final now = _now;
    return [..._waiting.values.where((w) => now - w.lastSeen <= staleMs)]..sort((a, b) => a.key.compareTo(b.key));
  }

  void _onLobby(NostrEvent e) {
    if (e.kind != TableKinds.waiting || e.pubkey == house) return;
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    if (c['kind'] != 'wait') return;
    final now = _now;
    if (_seated.hides(e.pubkey, now)) return;
    // A waiter is seated only with the service's word that its key is an
    // account's device.
    final licence = Licence.parse(c['licence']);
    if (!licenceFits(licence, e.pubkey, at: DateTime.fromMillisecondsSinceEpoch(now))) return;
    final w = _waiting.putIfAbsent(
      e.pubkey,
      () => Waiter(
        key: e.pubkey,
        name: cleanName(c['name'] as String? ?? ''),
        rating: c['rating'] as int? ?? 1500,
        pace: switch (c['pace']) { final int p when p > 0 && p <= 120 => p, _ => 0 },
        // How long they have waited, by this clock: rounds, windows and
        // the wait before bots are all the house's.
        since: now,
        avatar: c['avatar'] is Map ? Map<String, Object?>.from(c['avatar'] as Map) : null,
        licence: licence,
      ),
    );
    w.lastSeen = now;
    // Said again with every heartbeat, and changed by a choice made
    // while waiting; never past the most anyone waits.
    w.botsAfterMs = switch (c['botsAfter']) { final int b when b >= 0 && b <= WaitingRoom.personAtMostMs => b, _ => null };
    _heardAt = now;
    _idle = false;
  }

  void _tick() {
    final now = _now;
    _seated.prune(now);
    _waiting.removeWhere((_, w) => now - w.lastSeen > staleMs);
    if (!_idle && now - _heardAt >= idleMs) {
      _idle = true;
      log?.call('$pool: nobody waiting');
      onIdle?.call();
      return;
    }
    // The house seats a fifth of the way into the round, when the
    // heartbeats have settled.
    final round = now ~/ roundMs;
    if (!_ready || round == _hosted || now - round * roundMs < roundMs ~/ 5) return;
    _hosted = round;
    _seat(round, now);
  }

  void _seat(int round, int now) {
    final all = present;
    if (all.isEmpty) return;
    final p = plan(all, nowMs: now, roundMs: roundMs, botsAfterMs: botsAfterMs, random: _random);
    if (p.tables.isEmpty) return;
    log?.call('$pool round $round: ${all.length} waiting, ${p.tables.length} table(s)');
    for (final humans in p.tables) {
      final seed = _random.nextInt(1 << 31);
      final mean = humans.map((w) => w.rating).reduce((a, b) => a + b) ~/ humans.length;
      final wanted = seatCount - humans.length;
      final picked = bots(mean, wanted, Random(seed));
      TableSpec spec({String? salt}) => TableSpec(
            seed: seed,
            seats: [
              for (var s = 0; s < seatCount; s++)
                s < humans.length ? HumanSeat(humans[s].key, licence: humans[s].licence) : BotSeat(picked[s - humans.length]),
            ],
            rated: pool == 'rated',
            sealed: true,
            target: target,
            timing: timing,
            house: house,
            salt: salt,
          );
      final salt = seatingSalt(secret, spec());
      final table = spec(salt: salt);
      relay.announce({
        'kind': 'match',
        'round': round,
        'table': table.id,
        'salt': salt,
        'seed': seed,
        'rated': pool == 'rated',
        'sealed': true,
        'target': target,
        'timing': timing.toJson(),
        'house': house,
        'seats': [
          for (var s = 0; s < seatCount; s++)
            if (s < humans.length)
              {
                'key': humans[s].key,
                'name': humans[s].name,
                if (humans[s].avatar != null) 'avatar': humans[s].avatar,
                if (humans[s].licence != null) 'licence': humans[s].licence!.toJson(),
              }
            else
              {'bot': picked[s - humans.length].id},
        ],
        'policy': botPolicyVersion,
      });
      for (final w in humans) {
        _waiting.remove(w.key);
        _seated.add(w.key, now);
      }
    }
  }

  void close() {
    _timer?.cancel();
    _sub?.cancel();
  }
}

/// Whom a seating named, and when: not heard as waiting for [forMs]
/// after, which is longer than a heartbeat they said before the seating
/// reached them takes to arrive. What they say after that is heard: a
/// device that never took its seating is still waiting.
class _Seated {
  _Seated(this.forMs);

  final int forMs;
  final Map<PublicKey, int> _at = {};

  void add(PublicKey key, int now) => _at[key] = now;

  bool hides(PublicKey key, int now) {
    final at = _at[key];
    return at != null && now - at < forMs;
  }

  void prune(int now) => _at.removeWhere((_, at) => now - at >= forMs);
}
