/// A room: the lobby before a live table, over the relay.
///
/// Whoever hosts announces the room under its code; whoever joins
/// announces themselves; the host starts it, naming the seats — humans
/// in the order they came, bots in the rest — and everyone builds the
/// same [TableSpec] from that one signed event. The relay keeps lobby
/// events, so a joiner sees a room announced before it arrived.
///
/// The table starts ten seconds after the last person joins, or when
/// four are in, or when the host says so; empty seats are bots.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

class RoomMember {
  const RoomMember(this.key, this.name);
  final PublicKey key;
  final String name;
}

class Room extends ChangeNotifier {
  Room._({required this.relay, required this.code, required this.myName, required this.isHost});

  /// Announces a new room on the relay.
  factory Room.host({required RelayTransport relay, required String code, required String name}) {
    final r = Room._(relay: relay, code: code, myName: name, isHost: true);
    r._listen();
    relay.announce({'kind': 'host', 'name': name, 'seed': Random.secure().nextInt(1 << 31)});
    return r;
  }

  /// Joins a room announced on the relay.
  factory Room.join({required RelayTransport relay, required String code, required String name}) {
    final r = Room._(relay: relay, code: code, myName: name, isHost: false);
    r._listen();
    relay.announce({'kind': 'join', 'name': name});
    return r;
  }

  static const startAfter = Duration(seconds: 10);

  /// A code people can read out: four letters, no lookalikes.
  static String newCode([Random? random]) {
    const letters = 'ABCDEFGHJKMNPQRSTUVWXYZ';
    final rng = random ?? Random.secure();
    return List.generate(4, (_) => letters[rng.nextInt(letters.length)]).join();
  }

  final RelayTransport relay;
  final String code;
  final String myName;
  final bool isHost;

  PublicKey? host;
  int? _seed;
  final List<RoomMember> _members = [];
  int _lastJoinAt = 0; // relay time, seconds
  StreamSubscription<NostrEvent>? _sub;
  Timer? _timer;

  /// Host first, then in order of joining.
  List<RoomMember> get members => List.unmodifiable(_members);

  PublicKey get me => relay.signer.publicKey;

  /// Set once the start event is seen; the table can be built.
  TableSpec? spec;

  /// Seat number to the human's name, from the start event.
  Map<int, String> seatNames = const {};

  /// Whether the host has been heard from (a joiner's room may not exist).
  bool get found => host != null;

  /// Seconds until the host starts the table on its own, when two or
  /// more are in; null otherwise.
  int? get secondsToStart {
    if (spec != null || _members.length < 2) return null;
    final elapsed = DateTime.now().millisecondsSinceEpoch ~/ 1000 - _lastJoinAt;
    return (startAfter.inSeconds - elapsed).clamp(0, startAfter.inSeconds);
  }

  void _listen() {
    // What the relay replayed on connection, then what comes live.
    for (final e in List.of(relay.lobbySoFar)) {
      _onLobby(e);
    }
    _sub = relay.lobby.listen(_onLobby);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isHost && spec == null && secondsToStart == 0) start();
      notifyListeners();
    });
  }

  void _onLobby(NostrEvent e) {
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    switch (c['kind']) {
      case 'host':
        if (host != null && host != e.pubkey) return; // one host per code: first wins
        host = e.pubkey;
        _seed = c['seed'] as int?;
        _add(RoomMember(e.pubkey, c['name'] as String? ?? 'Host'), e.createdAt, first: true);
      case 'join':
        if (spec != null) return; // late; not this game
        _add(RoomMember(e.pubkey, c['name'] as String? ?? 'Someone'), e.createdAt);
        if (isHost && _members.length >= seatCount) start();
      case 'start':
        if (e.pubkey != host || spec != null) return;
        _applyStart(c);
    }
    notifyListeners();
  }

  void _add(RoomMember m, int at, {bool first = false}) {
    if (_members.any((x) => x.key == m.key)) return;
    if (first) {
      _members.insert(0, m);
    } else {
      _members.add(m);
      _lastJoinAt = max(_lastJoinAt, at);
    }
  }

  /// The host starts the table now: humans in join order, bots after.
  void start() {
    if (!isHost || spec != null || _seed == null) return;
    final rng = Random(_seed!);
    final draw = List.of(Persona.roster)..shuffle(rng);
    final seats = <Map<String, Object?>>[];
    for (var s = 0; s < seatCount; s++) {
      if (s < _members.length) {
        seats.add({'key': _members[s].key, 'name': _members[s].name});
      } else {
        seats.add({'bot': draw[s].name});
      }
    }
    relay.announce({'kind': 'start', 'seed': _seed, 'seats': seats});
  }

  void _applyStart(Map<String, Object?> c) {
    final seed = c['seed'] as int;
    final seats = <SeatHolder>[];
    final names = <int, String>{};
    var s = 0;
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
    if (seats.length != seatCount) return;
    spec = TableSpec(id: code, seed: seed, seats: seats);
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
