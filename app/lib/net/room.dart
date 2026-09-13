/// A room: friends at one code, before a live table, over the relay.
///
/// Nobody hosts. Everyone who enters a code says so on the relay every
/// two seconds — an ephemeral beat carrying their name, a seed, when
/// they arrived and the bot policy they run — and everyone in the room
/// keeps the same list: whoever has been heard in the last seven
/// seconds, in the order they arrived. The lowest key present leads.
/// The leader starts the table ten seconds after the last arrival once
/// two or more are in, at once when four are, or when its person
/// presses Start now; empty seats are bots. One signed start event
/// names the seats, and everyone builds the same [TableSpec] from it.
/// A leader that leaves is simply no longer present, and the next key
/// leads — there is no host to wait for, and nothing to hand over.
///
/// A start counts only from someone present, and only if it is
/// recent: the relay keeps start events, and a code reused an hour
/// later must not seat a newcomer at a table long finished.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import '../crypto/deal.dart';

class RoomMember {
  const RoomMember(this.key, this.name, {this.since = 0});
  final PublicKey key;
  final String name;

  /// When they arrived, by their own clock (ms): the seat order.
  final int since;
}

/// What a room needs of the relay: the lobby events under its code,
/// and a way to publish one. A [RelayTransport] is one; a test's bus
/// is another.
abstract interface class RoomChannel {
  PublicKey get me;
  List<NostrEvent> get lobbySoFar;
  Stream<NostrEvent> get lobby;
  void announce(Map<String, Object?> content, {bool ephemeral = false});
}

class RelayRoomChannel implements RoomChannel {
  RelayRoomChannel(this.relay);
  final RelayTransport relay;
  @override
  PublicKey get me => relay.signer.publicKey;
  @override
  List<NostrEvent> get lobbySoFar => relay.lobbySoFar;
  @override
  Stream<NostrEvent> get lobby => relay.lobby;
  @override
  void announce(Map<String, Object?> content, {bool ephemeral = false}) => relay.announce(content, ephemeral: ephemeral);
}

class _Present {
  _Present(this.member, this.policy, this.seed, this.arrivedHere);
  RoomMember member;
  int? policy;
  int seed;

  /// When this device first heard them, by its own clock: the
  /// countdown runs from the latest of these.
  final int arrivedHere;
  int lastHeard = 0;
}

class Room extends ChangeNotifier {
  Room({
    required this.channel,
    required this.code,
    required this.myName,
    this.heartbeatMs = 2000,
    this.staleMs = 7000,
    this.startAfterMs = 10000,
    int Function()? nowMs,
    Random? random,
  })  : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        seed = (random ?? Random.secure()).nextInt(1 << 31) {
    since = _nowMs();
    for (final e in List.of(channel.lobbySoFar)) {
      _onLobby(e);
    }
    _sub = channel.lobby.listen(_onLobby);
    _say();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  /// Into the room under [code] on [relay], as [name].
  factory Room.enter({required RelayTransport relay, required String code, required String name}) =>
      Room(channel: RelayRoomChannel(relay), code: code, myName: name);

  static const startAfter = Duration(seconds: 10);

  /// A code people can read out: four letters, no lookalikes.
  static String newCode([Random? random]) {
    const letters = 'ABCDEFGHJKMNPQRSTUVWXYZ';
    final rng = random ?? Random.secure();
    return List.generate(4, (_) => letters[rng.nextInt(letters.length)]).join();
  }

  /// A code as typed or shared: four letters or digits.
  static bool validCode(String s) => RegExp(r'^[A-Z0-9]{4}$').hasMatch(s);

  final RoomChannel channel;
  final String code;
  final String myName;
  final int heartbeatMs;

  /// A member not heard from for this long has left.
  final int staleMs;

  /// How long after the last arrival the leader starts, with two or
  /// more in.
  final int startAfterMs;
  final int Function() _nowMs;

  /// My arrival, by my clock; my seed, should I lead.
  late final int since;
  final int seed;

  /// Why this device will not sit at the table, if so: the leader's
  /// bots play by a different version of the policy, or this browser
  /// cannot run the deal.
  String? refusal;

  final Map<PublicKey, _Present> _others = {};

  /// A start that seats this device, from someone not heard from yet
  /// — the leader saw four and started before its own first beat
  /// reached here — held for their beat, which is at most two seconds
  /// off, and dropped after the stale window as a start from nobody.
  ({Map<String, Object?> content, PublicKey from, int heldAt})? _heldStart;
  int _lastSaid = -1 << 30;
  int _lastArrival = 0;
  bool _started = false;
  StreamSubscription<NostrEvent>? _sub;
  Timer? _timer;

  /// Set once the start event is seen; the table can be built.
  TableSpec? spec;

  /// Seat number to the human's name, from the start event.
  Map<int, String> seatNames = const {};

  PublicKey get me => channel.me;

  /// Everyone present, this device included, in the order they
  /// arrived — which is the seat order.
  List<RoomMember> get members {
    final now = _nowMs();
    final all = [
      RoomMember(me, myName, since: since),
      for (final p in _others.values)
        if (now - p.lastHeard <= staleMs) p.member,
    ];
    all.sort((a, b) => a.since != b.since ? a.since.compareTo(b.since) : a.key.compareTo(b.key));
    return List.unmodifiable(all);
  }

  /// Who leads: the lowest key present.
  PublicKey get leader => members.map((m) => m.key).reduce((a, b) => a.compareTo(b) <= 0 ? a : b);

  bool get amLeader => leader == me;

  /// Seconds until the leader starts the table on its own, when two or
  /// more are in; null otherwise.
  int? get secondsToStart {
    if (spec != null || members.length < 2) return null;
    final elapsed = _nowMs() - _lastArrival;
    return ((startAfterMs - elapsed) / 1000).ceil().clamp(0, startAfterMs ~/ 1000);
  }

  void _say() {
    if (spec != null) return;
    channel.announce({'kind': 'here', 'name': myName, 'seed': seed, 'since': since, 'policy': botPolicyVersion}, ephemeral: true);
    _lastSaid = _nowMs();
  }

  bool _present(PublicKey key) => key == me || members.any((m) => m.key == key);

  void _tick() {
    if (spec != null) return;
    final now = _nowMs();
    if (now - _lastSaid >= heartbeatMs) _say();
    final held = _heldStart;
    if (held != null && now - held.heldAt > staleMs) _heldStart = null;
    // The leader's policy is the table's: a mismatch is known before
    // the start, not at it.
    final lead = _others[leader];
    if (lead != null && lead.policy != botPolicyVersion) refusal = _mismatch;
    if (amLeader && !_started) {
      final n = members.length;
      if (n >= seatCount || (n >= 2 && now - _lastArrival >= startAfterMs)) start();
    }
    notifyListeners();
  }

  void _onLobby(NostrEvent e) {
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    if (e.pubkey == me && c['kind'] != 'start') return;
    final now = _nowMs();
    switch (c['kind']) {
      case 'here':
        if (spec != null) return;
        final p = _others[e.pubkey];
        final member = RoomMember(e.pubkey, c['name'] as String? ?? 'Someone', since: c['since'] as int? ?? now);
        if (p == null || now - p.lastHeard > staleMs) {
          // New, or back after going quiet: an arrival either way, and
          // the countdown starts over.
          _others[e.pubkey] = _Present(member, c['policy'] as int?, c['seed'] as int? ?? 0, now)..lastHeard = now;
          _lastArrival = now;
        } else {
          p
            ..member = member
            ..policy = c['policy'] as int?
            ..seed = c['seed'] as int? ?? p.seed
            ..lastHeard = now;
        }
        final held = _heldStart;
        if (held != null && held.from == e.pubkey) {
          _heldStart = null;
          _applyStart(held.content);
        }
      case 'start':
        if (spec != null) return;
        // Recent, or not this room's: the relay keeps starts, and a
        // code long finished with gets reused.
        final at = c['at'] as int?;
        if (at == null || (now - at).abs() > 120000) return;
        // One that seats this device has to come from someone here —
        // heard within the stale window, as the leader was a moment
        // ago — or it is a table this device was seated at earlier
        // under this code and left, not one to sit down at again. One
        // that does not is news: the table filled without you.
        final seatsMe = (c['seats'] as List? ?? const []).any((raw) => raw is Map && raw['key'] == me);
        if (seatsMe && !_present(e.pubkey)) {
          _heldStart = (content: c, from: e.pubkey, heldAt: now);
          return;
        }
        _applyStart(c);
    }
    notifyListeners();
  }

  /// The leader starts the table now: everyone here in arrival order,
  /// bots in the rest. A no-op for anyone else, or alone.
  void start() {
    if (!amLeader || spec != null || _started || members.length < 2) return;
    _started = true;
    final rng = Random(seed);
    final draw = List.of(Persona.roster)..shuffle(rng);
    final here = members;
    final seats = <Map<String, Object?>>[];
    for (var s = 0; s < seatCount; s++) {
      if (s < here.length) {
        seats.add({'key': here[s].key, 'name': here[s].name});
      } else {
        seats.add({'bot': draw[s].id});
      }
    }
    channel.announce({
      'kind': 'start',
      'seed': seed,
      'seats': seats,
      'policy': botPolicyVersion,
      'sealed': dealCrypto != null,
      'at': _nowMs(),
    });
  }

  static const _mismatch = "Someone's app is on another build than yours — one of you is older. Update, and try again.";
  static const _noDeal = "This browser can't run the deal that keeps the cards honest. Try a current Chrome, Firefox or Safari.";

  void _applyStart(Map<String, Object?> c) {
    final seed = c['seed'] as int;
    final seats = <SeatHolder>[];
    final names = <int, String>{};
    var s = 0;
    try {
      for (final raw in c['seats'] as List) {
        final m = Map<String, Object?>.from(raw as Map);
        if (m['bot'] is String) {
          seats.add(BotSeat(Persona.named(m['bot'] as String)));
        } else {
          seats.add(HumanSeat(m['key'] as String));
          names[s] = m['name'] as String? ?? 'Someone';
        }
        s++;
      }
    } catch (_) {
      return; // another build's idea of a table
    }
    if (seats.length != seatCount) return;
    // Every client computes the bots' plays itself; two versions of the
    // policy at one table fork it. Better not to sit down. A table
    // that has no seat for this device is only news, whatever it runs.
    final mine = seats.any((h) => h is HumanSeat && h.key == me);
    if (mine && c['policy'] != botPolicyVersion) {
      refusal = _mismatch;
      return;
    }
    final sealed = c['sealed'] == true;
    if (mine && sealed && dealCrypto == null) {
      refusal = _noDeal;
      return;
    }
    spec = TableSpec(id: code, seed: seed, seats: seats, sealed: sealed);
    seatNames = names;
  }

  /// Whether this device holds a seat once the table starts.
  bool get seated => spec?.seatOf(me) != null;

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
