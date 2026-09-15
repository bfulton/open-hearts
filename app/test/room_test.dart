/// The room without a host, on a fake bus and a fake clock: whoever
/// is there is the table, the lowest key leads, the leader starts ten
/// seconds after the last arrival or at four, a stale start is not a
/// table, and a late arrival is told.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:engine/engine.dart' show botPolicyVersion;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/net/room.dart';
import 'package:table/table.dart';

/// A relay's lobby channel for one code, shared by every device on
/// the bus: what one announces, all hear on the next microtask.
class Bus {
  final List<NostrEvent> stored = [];
  final List<BusChannel> channels = [];

  BusChannel attach(Signer signer) {
    final c = BusChannel(this, signer);
    channels.add(c);
    return c;
  }

  void publish(NostrEvent e, {required bool ephemeral}) {
    if (!ephemeral) stored.add(e);
    for (final c in channels) {
      c._in.add(e);
    }
  }
}

class BusChannel implements RoomChannel {
  BusChannel(this.bus, this.signer);
  final Bus bus;
  final Signer signer;
  final _in = StreamController<NostrEvent>.broadcast();

  @override
  PublicKey get me => signer.publicKey;
  @override
  List<NostrEvent> get lobbySoFar => List.of(bus.stored);
  @override
  Stream<NostrEvent> get lobby => _in.stream;
  @override
  void announce(Map<String, Object?> content, {bool ephemeral = false}) {
    bus.publish(NostrEvent.sign(signer, kind: ephemeral ? 24245 : 4244, content: jsonEncode(content), tags: const [['t', 'ROOM']]), ephemeral: ephemeral);
  }
}

void main() {
  test('a code is eight characters, none of them a lookalike, and no two alike', () {
    expect(Room.validCode('ABCDEFGH'), isTrue);
    expect(Room.validCode('A1B2C3D4'), isTrue, reason: 'what another build sends is still a code');
    expect(Room.validCode('abcdefgh'), isFalse, reason: 'upper-cased before it gets here');
    expect(Room.validCode('ABCDEF-H'), isFalse);
    expect(Room.validCode('ABCD'), isFalse, reason: 'four of them was a door a stranger could walk through');
    expect(Room.validCode('ABCDEFGHI'), isFalse);
    expect(Room.validCode(''), isFalse);
    final drawn = <String>{};
    for (var i = 0; i < 300; i++) {
      final code = Room.newCode();
      expect(Room.validCode(code), isTrue);
      expect(code, matches(RegExp(r'^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$')),
          reason: 'nothing in it is read or typed as something else');
      drawn.add(code);
    }
    expect(drawn.length, 300, reason: 'every table a code of its own');
  });

  test('two arrive, the lowest key leads, and the table starts ten seconds after the second', () {
    fakeAsync((async) {
      final bus = Bus();
      final signers = [FakeSigner('a'), FakeSigner('b')];
      int now() => async.elapsed.inMilliseconds;
      final a = Room(channel: bus.attach(signers[0]), code: 'ROOM', myName: 'Ada', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      expect(a.members.map((m) => m.name), ['Ada']);
      expect(a.amLeader, isTrue, reason: 'alone, you lead');
      expect(a.secondsToStart, isNull);

      final b = Room(channel: bus.attach(signers[1]), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      expect(a.members.map((m) => m.name), ['Ada', 'Bao'], reason: 'arrival order');
      expect(b.members.map((m) => m.name), ['Ada', 'Bao']);
      final lowest = signers.map((s) => s.publicKey).reduce((x, y) => x.compareTo(y) <= 0 ? x : y);
      expect(a.leader, lowest);
      expect(b.leader, lowest);
      expect(a.amLeader != b.amLeader, isTrue, reason: 'exactly one leads');
      expect(a.secondsToStart, inInclusiveRange(6, 8), reason: 'counting down from Bao\'s arrival');
      expect(a.spec, isNull);

      async.elapse(const Duration(seconds: 8));
      expect(a.spec, isNotNull, reason: 'the leader started it');
      expect(b.spec, isNotNull);
      expect(a.spec!.seats.map((s) => s.toString()), b.spec!.seats.map((s) => s.toString()), reason: 'one table');
      expect(a.seated && b.seated, isTrue);
      expect(a.spec!.seats.whereType<HumanSeat>().map((h) => h.key).toSet(), {signers[0].publicKey, signers[1].publicKey},
          reason: 'both of them, in whichever seats the draw gave');
      expect(a.spec!.seats.whereType<BotSeat>().length, 2);
      // The table's id is its own, under the code: a reused code must
      // not put two tables' events on one tag.
      expect(a.spec!.id, startsWith('ROOM-'));
      expect(a.spec!.id, b.spec!.id);
      expect(a.spec!.id, isNot('ROOM'));
      a.dispose();
      b.dispose();
    });
  });

  test('four in: it starts at once; a fifth is told the table filled without them', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final rooms = [for (final n in ['Ada', 'Bao', 'Cara', 'Dee']) Room(channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 3));
      expect(rooms.every((r) => r.spec != null), isTrue, reason: 'four is a table');
      expect(rooms.every((r) => r.seated), isTrue);
      expect(rooms.first.spec!.seats.whereType<BotSeat>(), isEmpty);
      final late = Room(channel: bus.attach(FakeSigner('Eve')), code: 'ROOM', myName: 'Eve', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      expect(late.spec, isNotNull, reason: 'the start is on the relay');
      expect(late.seated, isFalse);
      for (final r in [...rooms, late]) {
        r.dispose();
      }
    });
  });

  test('a room that is already decided says so to whoever comes to listen', () {
    fakeAsync((async) {
      // The page enters the room and then listens, so a room that finds
      // its answer inside its own constructor — the start was on the
      // relay before this device asked for the code — has nobody to
      // tell. Told late is the difference between being sent back to
      // the front door and sitting in a room that will never fill.
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final rooms = [for (final n in ['Ada', 'Bao', 'Cara', 'Dee']) Room(channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 3));
      expect(rooms.every((r) => r.seated), isTrue);

      final late = Room(channel: bus.attach(FakeSigner('Eve')), code: 'ROOM', myName: 'Eve', nowMs: now);
      expect(late.spec, isNotNull, reason: 'decided in the constructor, before anyone listens');
      var told = 0;
      late.addListener(() => told++);
      async.elapse(const Duration(seconds: 2));
      expect(told, greaterThan(0), reason: 'and said to the listener that came after');
      expect(late.seated, isFalse);
      for (final r in [...rooms, late]) {
        r.dispose();
      }
    });
  });

  test('the leader\'s game is the table\'s: the score it runs to rides in the start event', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      // Two devices asking for different games. Only the one that
      // starts the table has a say, and everyone plays that game.
      final rooms = [
        for (final n in ['Ada', 'Bao'])
          Room(channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, target: n == 'Ada' ? 100 : 50, nowMs: now)
      ];
      async.elapse(const Duration(seconds: 14));
      final leader = rooms.firstWhere((r) => r.amLeader);
      expect(rooms.every((r) => r.spec != null), isTrue);
      for (final r in rooms) {
        expect(r.spec!.target, leader.target, reason: 'one table, one game');
      }
      for (final r in rooms) {
        r.dispose();
      }
    });
  });

  test('the seat you get is drawn, not won by arriving first', () {
    // Four people in the same order every time, at tables whose codes
    // differ: the seating follows the table's seed, so being second
    // through the door is not a seat.
    final orders = <String>{};
    for (final code in ['AAAA', 'BBBB', 'CCCC', 'DDDD', 'EEEE', 'FFFF']) {
      fakeAsync((async) {
        final bus = Bus();
        int now() => async.elapsed.inMilliseconds;
        final rooms = [for (final n in ['Ada', 'Bao', 'Cara', 'Dee']) Room(channel: bus.attach(FakeSigner(n)), code: code, myName: n, nowMs: now)];
        async.elapse(const Duration(seconds: 3));
        final spec = rooms.first.spec!;
        expect(spec.seats.whereType<HumanSeat>(), hasLength(4), reason: 'everyone is seated');
        // Every one of them, once: a draw, not a reshuffle of who is there.
        expect(spec.seats.map((h) => (h as HumanSeat).key).toSet(), rooms.map((r) => r.me).toSet());
        final order = spec.seats.map((h) => (h as HumanSeat).key).join(',');
        orders.add(order);
        // And all four build the same table from the one start event.
        for (final r in rooms) {
          expect(r.spec!.seats.map((h) => (h as HumanSeat).key).join(','), order);
          r.dispose();
        }
      });
    }
    expect(orders, hasLength(greaterThan(1)), reason: 'the same four do not always sit the same way');
  });

  test('Start now is the leader\'s, and only with company', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final a = Room(channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      a.start();
      async.elapse(const Duration(seconds: 1));
      expect(a.spec, isNull, reason: 'alone');
      final b = Room(channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      final follower = a.amLeader ? b : a;
      final leader = a.amLeader ? a : b;
      follower.start();
      async.elapse(const Duration(seconds: 1));
      expect(a.spec, isNull, reason: 'not the follower\'s to start');
      leader.start();
      async.elapse(const Duration(seconds: 1));
      expect(a.spec, isNotNull);
      expect(b.spec, isNotNull);
      a.dispose();
      b.dispose();
    });
  });

  test('a leader who leaves is simply gone: the next key leads, and the countdown is from the last arrival', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final a = Room(channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      final b = Room(channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      final leader = a.amLeader ? a : b;
      final other = a.amLeader ? b : a;
      // The leader's app closes: no more beats. Within the stale window
      // the other still counts them; after it, the other leads alone.
      leader.dispose();
      async.elapse(const Duration(seconds: 4));
      expect(other.members.length, 2);
      async.elapse(const Duration(seconds: 5));
      expect(other.members.length, 1, reason: 'not heard from for seven seconds');
      expect(other.amLeader, isTrue);
      expect(other.spec, isNull, reason: 'alone again, nothing starts');
      // A third arrives: the countdown runs from them.
      final c = Room(channel: bus.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      expect(other.members.map((m) => m.name).toSet(), {other.myName, 'Cara'});
      async.elapse(const Duration(seconds: 9));
      expect(other.spec, isNotNull);
      expect(c.spec, isNotNull);
      expect(other.spec!.seats.whereType<HumanSeat>().length, 2, reason: 'the one who left holds no seat');
      other.dispose();
      c.dispose();
    });
  });

  test('a start that seats me from someone not heard yet waits for their beat', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final a = FakeSigner('a');
      final b = Room(channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      // Ada saw four and started before her first beat reached Bao.
      bus.publish(NostrEvent.sign(a, kind: 4244, content: jsonEncode({
        'kind': 'start', 'seed': 1, 'policy': botPolicyVersion, 'sealed': false, 'at': now(),
        'seats': [
          {'key': a.publicKey, 'name': 'Ada'}, {'key': b.me, 'name': 'Bao'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 1));
      expect(b.spec, isNull, reason: 'held, not taken, until Ada is heard');
      // Her beat arrives, as it does within two seconds.
      bus.attach(a).announce({'kind': 'here', 'name': 'Ada', 'seed': 1, 'since': now() - 5000, 'policy': botPolicyVersion}, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      expect(b.spec, isNotNull, reason: 'taken once she is here');
      expect(b.seated, isTrue);
      b.dispose();

      // And held only so long: a beat that never comes is nobody. A
      // fresh bus, since the start above is on the relay and would be
      // news to Cara — a table that filled without her.
      final bus2 = Bus();
      final c = Room(channel: bus2.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
      final ghost = FakeSigner('ghost');
      async.elapse(const Duration(seconds: 1));
      bus2.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        'kind': 'start', 'seed': 1, 'policy': botPolicyVersion, 'sealed': false, 'at': now(),
        'seats': [
          {'key': ghost.publicKey, 'name': 'Ghost'}, {'key': c.me, 'name': 'Cara'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 9));
      bus2.attach(ghost).announce({'kind': 'here', 'name': 'Ghost', 'seed': 1, 'since': now(), 'policy': botPolicyVersion}, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      expect(c.spec, isNull, reason: 'dropped after the stale window');
      c.dispose();
    });
  });

  test('how you look travels with you: the icon and colour in every beat, the picture once, and all of it into the seats', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final picture = Uint8List.fromList(List.generate(200, (i) => (i * 7) % 256));
      final a = Room(channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', myAvatar: Avatar(icon: 'rocket', color: 3, picture: picture), nowMs: now);
      final b = Room(channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', myAvatar: const Avatar(icon: 'cake'), nowMs: now);
      async.elapse(const Duration(seconds: 3));
      final adaAtB = b.members.firstWhere((m) => m.name == 'Ada');
      expect(adaAtB.avatar, Avatar(icon: 'rocket', color: 3, picture: picture), reason: 'icon, colour and picture');
      expect(a.members.firstWhere((m) => m.name == 'Bao').avatar, const Avatar(icon: 'cake'));
      // A third arrives after the picture went by: the relay kept it.
      final c = Room(channel: bus.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      expect(c.members.firstWhere((m) => m.name == 'Ada').avatar.picture, picture);
      async.elapse(const Duration(seconds: 10));
      expect(c.spec, isNotNull);
      final adaSeat = c.spec!.seats.indexWhere((h) => h is HumanSeat && h.key == a.me);
      expect(c.seatAvatars[adaSeat], Avatar(icon: 'rocket', color: 3, picture: picture));
      final caraSeat = c.spec!.seats.indexWhere((h) => h is HumanSeat && h.key == c.me);
      expect(c.seatAvatars[caraSeat], Avatar.none);
      for (final r in [a, b, c]) {
        r.dispose();
      }
    });
  });

  test('a start from long ago, or from nobody here, is not a table', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final ghost = FakeSigner('ghost');
      // The relay still holds the start of a game under this code an
      // hour ago, by someone who is not here.
      bus.stored.add(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        'kind': 'start', 'seed': 1, 'policy': botPolicyVersion, 'sealed': false, 'at': now() - 3600000,
        'seats': [
          {'key': ghost.publicKey, 'name': 'Ghost'}, {'bot': 'Westley'}, {'bot': 'Romeo'}, {'bot': 'Juliet'},
        ],
      }), tags: const [['t', 'ROOM']]));
      final a = Room(channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      async.elapse(const Duration(seconds: 2));
      expect(a.spec, isNull);
      expect(a.members.length, 1);
      // And a recent one from someone not present: still not a table.
      bus.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        'kind': 'start', 'seed': 1, 'policy': botPolicyVersion, 'sealed': false, 'at': now(),
        'seats': [
          {'key': a.me, 'name': 'Ada'}, {'bot': 'Westley'}, {'bot': 'Romeo'}, {'bot': 'Juliet'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 2));
      expect(a.spec, isNull, reason: 'nobody here started it');
      a.dispose();
    });
  });
}
