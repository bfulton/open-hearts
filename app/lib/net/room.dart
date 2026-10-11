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

import 'package:engine/engine.dart';
import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

import '../avatar.dart';
import '../crypto/deal.dart';
import '../l10n/l10n.dart';
import 'remote_config.dart' show waits;

class RoomMember {
  const RoomMember(this.key, this.name, {this.since = 0, this.avatar = Avatar.none, this.licence});
  final PublicKey key;
  final String name;

  /// The service's word that [key] is a device of an account
  /// (packages/table, licence.dart), from their beats and into the
  /// start: every seat checks every other's.
  final Licence? licence;

  /// When they arrived, by their own clock (ms): the seat order.
  final int since;

  /// As they chose to look: the icon and colour from their beats, the
  /// picture from the one event that carried it.
  final Avatar avatar;
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
  _Present(this.member, this.policy, this.seed);
  RoomMember member;
  int? policy;
  int seed;
  int lastHeard = 0;
}

/// Why a device will not sit at a room's table.
enum RoomRefusal {
  /// The leader's bots play by another version of the policy, or the
  /// start was made by a build that does not seal its tables.
  otherBuild,

  /// This device cannot run the deal.
  noDeal,

  /// The start names a seat the service has not vouched for: one whose
  /// key no licence names, or an account seated twice.
  unlicensed,
}

class Room extends ChangeNotifier {
  Room({
    required this.channel,
    required this.code,
    required this.myName,
    this.myAvatar = Avatar.none,
    this.target = gameOverScore,
    this.timing = TableTiming.standard,
    this.heartbeatMs = 2000,
    this.staleMs = 7000,
    int? startAfterMs,
    this.licence,
    int Function()? nowMs,
    Random? random,
    bool? canDeal,
  })  : startAfterMs = startAfterMs ?? waits.roomStart.inMilliseconds,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        seed = (random ?? Random.secure()).nextInt(1 << 31),
        canDeal = canDeal ?? dealReady {
    since = _nowMs();
    for (final e in List.of(channel.lobbySoFar)) {
      _onLobby(e);
    }
    // The start may already have been on the relay: a device that
    // opens the link a moment after the table began finds its answer
    // inside this constructor, before anyone can be listening for it,
    // and every notification after that is guarded by `spec`. So the
    // first tick says it once — otherwise the room is simply sat in,
    // waiting for a table that has already gone.
    _decidedInside = spec != null;
    _sub = channel.lobby.listen(_onLobby);
    _say();
    // The picture is heavy for a beat: once, stored under the code, so
    // whoever comes later reads it with the rest of the lobby.
    final picture = myAvatar.picture;
    if (picture != null) channel.announce({'kind': 'picture', 'jpeg': base64Encode(picture)});
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  /// Into the room under [code] on [relay], as [name], looking like
  /// [avatar], for a game to [target].
  factory Room.enter({
    required RelayTransport relay,
    required String code,
    required String name,
    Avatar avatar = Avatar.none,
    int target = gameOverScore,
    TableTiming timing = TableTiming.standard,
    Duration? startAfter,
    Licence? licence,
  }) =>
      Room(
        channel: RelayRoomChannel(relay),
        code: code,
        myName: name,
        myAvatar: avatar,
        target: target,
        timing: timing,
        startAfterMs: startAfter?.inMilliseconds,
        licence: licence,
      );

  /// How far apart two devices' clocks are allowed to be before a
  /// start made since this device arrived stops looking like one. Wider
  /// than any two browsers on a table ever are, and a device further
  /// out than this only falls back to waiting for a beat.
  static const _skewMs = 5000;

  /// A code for a private table: eight characters, from the system's
  /// own source of randomness. It is the only thing between a stranger
  /// and the table, and a code that can be guessed in a few thousand
  /// tries is no door at all. The alphabet leaves out the characters
  /// that are read or typed as one another — O and zero, I and one and
  /// a lowercase L — because a code still ends up read off one screen
  /// and into another now and then.
  static String newCode([Random? random]) {
    const alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    final rng = random ?? Random.secure();
    return List.generate(8, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
  }

  /// A code as shared: eight letters or digits. Wider than the
  /// alphabet a code is drawn from, since what arrives in a link is
  /// somebody else's build's idea of one.
  static bool validCode(String s) => RegExp(r'^[A-Z0-9]{8}$').hasMatch(s);

  final RoomChannel channel;
  final String code;
  final String myName;
  final Avatar myAvatar;

  /// The score a table started here runs to, as this device's options
  /// ask for it. Only the leader's counts, and it says so in the start
  /// event, because the four have to agree on when the game ends.
  final int target;

  /// The clocks of a table started here (timing.dart in the table
  /// package), as this device's remote config has them. Only the
  /// leader's count, and for the same reason as [target]: four seats
  /// that disagree about when a boot is due back different sides of
  /// it.
  final TableTiming timing;

  final int heartbeatMs;

  /// This device's licence, said with every beat and carried into the
  /// start. Where accounts are checked, a member without one is not
  /// seated, and a start that seats one is not sat at.
  final Licence? licence;

  /// A member not heard from for this long has left.
  final int staleMs;

  /// How long after the last arrival the leader starts, with two or
  /// more in: the operator's (waits.roomStart) unless given.
  final int startAfterMs;
  final int Function() _nowMs;

  /// My arrival, by my clock; my seed, should I lead.
  late final int since;
  final int seed;

  /// Why this device will not sit at the table, if so: the leader's
  /// bots play by a different version of the policy, or this device
  /// cannot run the deal. The screen says it ([Room.said]).
  RoomRefusal? refusal;

  /// Whether this device can run the deal: whether it loaded
  /// (crypto/deal.dart), unless a test says. Every live table is
  /// sealed, and a device that cannot run the deal does not sit down
  /// (docs/explanation/fair-deal.md) — nor start one, nor sit at a
  /// start that is not sealed.
  final bool canDeal;

  final Map<PublicKey, _Present> _others = {};

  /// Pictures by key, from the events that carried them — kept apart
  /// from presence, since one arrives once and may arrive first.
  final Map<PublicKey, Uint8List> _pictures = {};

  /// A start that seats this device, from someone not heard from yet
  /// — the leader saw four and started before its own first beat
  /// reached here — held for their beat, which is at most two seconds
  /// off, and dropped after the stale window as a start from nobody.
  ({Map<String, Object?> content, PublicKey from, int heldAt})? _heldStart;
  int _lastSaid = -1 << 30;
  int _lastArrival = 0;
  bool _started = false;

  /// Whether the table was decided before this room had a listener.
  /// Cleared by the tick that says so.
  bool _decidedInside = false;
  StreamSubscription<NostrEvent>? _sub;
  Timer? _timer;

  /// Set once the start event is seen; the table can be built.
  TableSpec? spec;

  /// Seat number to the human's name, from the start event.
  Map<int, String> seatNames = const {};

  /// Seat number to the human's avatar, from the start event and the
  /// pictures seen.
  Map<int, Avatar> seatAvatars = const {};

  PublicKey get me => channel.me;

  /// Everyone present, this device included, in the order they
  /// arrived — which is the seat order.
  List<RoomMember> get members {
    final now = _nowMs();
    final all = [
      RoomMember(me, myName, since: since, avatar: myAvatar, licence: licence),
      for (final p in _others.values)
        if (now - p.lastHeard <= staleMs) _withPicture(p.member),
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

  RoomMember _withPicture(RoomMember m) {
    final picture = _pictures[m.key];
    return picture == null ? m : RoomMember(m.key, m.name, since: m.since, avatar: m.avatar.copyWith(picture: picture), licence: m.licence);
  }

  void _say() {
    if (spec != null) return;
    channel.announce({
      'kind': 'here',
      'name': myName,
      'seed': seed,
      'since': since,
      'policy': botPolicyVersion,
      'avatar': myAvatar.toJson(withPicture: false),
      if (licence != null) 'licence': licence!.toJson(),
    }, ephemeral: true);
    _lastSaid = _nowMs();
  }

  bool _present(PublicKey key) => key == me || members.any((m) => m.key == key);

  void _tick() {
    if (spec != null) {
      if (_decidedInside) {
        _decidedInside = false;
        notifyListeners();
      }
      return;
    }
    final now = _nowMs();
    if (now - _lastSaid >= heartbeatMs) _say();
    final held = _heldStart;
    if (held != null && now - held.heldAt > staleMs) _heldStart = null;
    // The leader's policy is the table's: a mismatch is known before
    // the start, not at it.
    final lead = _others[leader];
    if (lead != null && lead.policy != botPolicyVersion) refusal = RoomRefusal.otherBuild;
    // Said before it is anyone's start rather than at one: the door
    // takes this device out of the room, and whoever is left leads.
    if (!canDeal) refusal = RoomRefusal.noDeal;
    if (amLeader && !_started && canDeal) {
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
      case 'picture':
        final raw = c['jpeg'];
        if (raw is! String) return;
        try {
          final bytes = base64Decode(raw);
          if (bytes.length <= Avatar.maxPictureBytes) _pictures[e.pubkey] = bytes;
        } catch (_) {
          return;
        }
      case 'here':
        if (spec != null) return;
        // In the room only on the service's word that the key is an
        // account's device, and never this device's own account again.
        final licence = Licence.parse(c['licence']);
        if (!licenceFits(licence, e.pubkey, at: DateTime.fromMillisecondsSinceEpoch(now))) return;
        if (licence != null && licence.account == this.licence?.account) return;
        final p = _others[e.pubkey];
        final member = RoomMember(e.pubkey, c['name'] as String? ?? 'Someone',
            since: c['since'] as int? ?? now, avatar: Avatar.fromJson(c['avatar']), licence: licence);
        if (p == null || now - p.lastHeard > staleMs) {
          // New, or back after going quiet: an arrival either way, and
          // the countdown starts over.
          _others[e.pubkey] = _Present(member, c['policy'] as int?, c['seed'] as int? ?? 0)..lastHeard = now;
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
        // One that seats this device has to be one this device could
        // be at: from someone here — heard within the stale window, as
        // the leader was a moment ago — or else this is a table that
        // was played under this code and left, not one to sit down at
        // again. One that seats this device and nobody here is held
        // for its sender's next beat, and dropped if none comes.
        //
        // Except a start that seats the device that sent it, made since
        // this device came into the room: that is this room's table,
        // not a leftover. The fourth to arrive gets exactly that, before
        // any beat of the leader's comes round — and none will, since
        // everyone else is at the table and has stopped beating — so
        // holding it would leave the fourth in a room the table has left.
        final seats = c['seats'] as List? ?? const [];
        bool holds(PublicKey? key) => seats.any((raw) => raw is Map && raw['key'] == key);
        final itsOwn = holds(e.pubkey) && at >= since - _skewMs;
        if (holds(me) && !_present(e.pubkey) && !itsOwn) {
          _heldStart = (content: c, from: e.pubkey, heldAt: now);
          return;
        }
        _applyStart(c);
    }
    notifyListeners();
  }

  /// The leader starts the table now: everyone here, in an order drawn
  /// from the table's own seed rather than the order they arrived in,
  /// so the seat you get is not a prize for being early; bots in the
  /// rest. A no-op for anyone else, or alone.
  void start() {
    if (!amLeader || spec != null || _started || members.length < 2) return;
    _started = true;
    final rng = Random(seed);
    final draw = List.of(Persona.roster)..shuffle(rng);
    final here = List.of(members)..shuffle(rng);
    final seats = <Map<String, Object?>>[];
    for (var s = 0; s < seatCount; s++) {
      if (s < here.length) {
        seats.add({
          'key': here[s].key,
          'name': here[s].name,
          'avatar': here[s].avatar.toJson(withPicture: false),
          if (here[s].licence != null) 'licence': here[s].licence!.toJson(),
        });
      } else {
        seats.add({'bot': draw[s].id});
      }
    }
    channel.announce({
      'kind': 'start',
      // The table's own id, not the code: a code is reused, and two
      // tables that start under one code — two halves of a room that
      // could not hear each other — must not hear each other's plays.
      'table': newTableId(),
      'seed': seed,
      'seats': seats,
      'policy': botPolicyVersion,
      // Every live table is sealed (docs/explanation/fair-deal.md).
      'sealed': true,
      'target': target,
      'timing': timing.toJson(),
      'at': _nowMs(),
    });
  }

  /// A refusal as the player is told it.
  static String said(RoomRefusal refusal, [AppLocalizations? words]) => switch (refusal) {
        RoomRefusal.otherBuild || RoomRefusal.unlicensed => (words ?? english).roomOtherBuild,
        RoomRefusal.noDeal => noDeal(words),
      };

  /// What a device that cannot run the deal is told, wherever it tries
  /// to sit at a live table. One whose deal loaded and then stopped —
  /// its worker failed for good (crypto/deal.dart) — can run it again
  /// from the start, and is told so.
  static String noDeal([AppLocalizations? words]) {
    final say = words ?? english;
    return switch ((kIsWeb, dealWorker?.dead ?? false)) {
      (true, true) => say.noDealPageStopped,
      (false, true) => say.noDealAppStopped,
      (true, false) => say.noDealBrowser,
      (false, false) => say.noDealBuild,
    };
  }

  void _applyStart(Map<String, Object?> c) {
    final seed = c['seed'] as int;
    final seats = <SeatHolder>[];
    final names = <int, String>{};
    final avatars = <int, Avatar>{};
    var s = 0;
    try {
      for (final raw in c['seats'] as List) {
        final m = Map<String, Object?>.from(raw as Map);
        if (m['bot'] is String) {
          seats.add(BotSeat(Persona.named(m['bot'] as String)));
        } else {
          final key = m['key'] as String;
          seats.add(HumanSeat(key, licence: m['licence'] == null ? null : Licence.parse(m['licence']) ?? (throw const FormatException('licence'))));
          names[s] = m['name'] as String? ?? 'Someone';
          final chosen = key == me ? myAvatar : Avatar.fromJson(m['avatar']);
          final picture = key == me ? myAvatar.picture : _pictures[key];
          avatars[s] = picture == null ? chosen : chosen.copyWith(picture: picture);
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
      refusal = RoomRefusal.otherBuild;
      return;
    }
    // Every live table is sealed: a start that is not was made by
    // another build, or by one that could not run the deal and sat
    // down anyway — and sitting at it would be dealt cards anyone at
    // the table could read. One this device cannot deal it cannot sit
    // at either.
    if (mine && c['sealed'] != true) {
      refusal = RoomRefusal.otherBuild;
      return;
    }
    if (mine && !canDeal) {
      refusal = RoomRefusal.noDeal;
      return;
    }
    // Named by the leader (above): a start without an id is another
    // build's.
    final id = c['table'];
    if (id is! String || !validTableId(id)) {
      if (mine) refusal = RoomRefusal.otherBuild;
      return;
    }
    final made = TableSpec(
      id: id,
      seed: seed,
      seats: seats,
      sealed: c['sealed'] == true,
      // The leader's game, not this device's: a start event from a
      // build that had no say says fifty.
      target: c['target'] as int? ?? gameOverScore,
      // And the leader's clocks: none said is the standard table, and
      // one out of bounds is too, at every seat alike.
      timing: TableTiming.parse(c['timing']),
    );
    // Every seat an account's by the service's word, each account once:
    // a start that is not is not a table to sit at.
    if (made.licenceProblem(at: DateTime.fromMillisecondsSinceEpoch(_nowMs())) != null) {
      if (mine) refusal = RoomRefusal.unlicensed;
      return;
    }
    spec = made;
    seatNames = names;
    seatAvatars = avatars;
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
