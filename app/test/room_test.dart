/// The room without a host, on a fake bus and a fake clock: whoever
/// is there is the table, the lowest key leads, the leader starts ten
/// seconds after the last arrival or at four, a stale start is not a
/// table, and a late arrival is told.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:engine/engine.dart' show Persona, botPolicyVersion;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/net/room.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

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

/// A table id as a leader names one.
const _table = '0123456789abcdef0123456789abcdef';

/// The house the rooms here play with.
const _house = 'dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8';

/// What a start says besides its seats for it to be a table this build
/// sits at: the house, and the clocks in full.
final _inFull = {'house': _house, 'timing': TableTiming.standard.toJson()};

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
      final a = Room(house: _house, canDeal: true, channel: bus.attach(signers[0]), code: 'ROOM', myName: 'Ada', nowMs: now);
      async.elapse(const Duration(seconds: 3));
      expect(a.members.map((m) => m.name), ['Ada']);
      expect(a.amLeader, isTrue, reason: 'alone, you lead');
      expect(a.secondsToStart, isNull);

      final b = Room(house: _house, canDeal: true, channel: bus.attach(signers[1]), code: 'ROOM', myName: 'Bao', nowMs: now);
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
      // The table's id is its own, not the code: a reused code must not
      // put two tables' events on one tag, and the id is the table's
      // address, so it is unguessable.
      expect(validTableId(a.spec!.id), isTrue, reason: a.spec!.id);
      expect(a.spec!.id, b.spec!.id);
      a.dispose();
      b.dispose();
    });
  });

  test('four in: it starts at once; a fifth is told the table filled without them', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final rooms = [for (final n in ['Ada', 'Bao', 'Cara', 'Dee']) Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 3));
      expect(rooms.every((r) => r.spec != null), isTrue, reason: 'four is a table');
      expect(rooms.every((r) => r.seated), isTrue);
      expect(rooms.first.spec!.seats.whereType<BotSeat>(), isEmpty);
      final late = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('Eve')), code: 'ROOM', myName: 'Eve', nowMs: now);
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
      final rooms = [for (final n in ['Ada', 'Bao', 'Cara', 'Dee']) Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 3));
      expect(rooms.every((r) => r.seated), isTrue);

      final late = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('Eve')), code: 'ROOM', myName: 'Eve', nowMs: now);
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
          Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, target: n == 'Ada' ? 100 : 50, nowMs: now)
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

  test('the leader\'s clocks are the table\'s: its timing rides in the start event', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      // Two devices whose remote configs say different clocks. Only the
      // one that starts the table has a say, as with the score.
      final quick = TableTiming.parse({'graceMs': 3000, 'botActsMs': 8000});
      final rooms = [
        for (final n in ['Ada', 'Bao'])
          Room(
              house: _house,
              canDeal: true,
              channel: bus.attach(FakeSigner(n)),
              code: 'ROOM',
              myName: n,
              timing: n == 'Ada' ? quick : TableTiming.standard,
              nowMs: now)
      ];
      async.elapse(const Duration(seconds: 14));
      final leader = rooms.firstWhere((r) => r.amLeader);
      for (final r in rooms) {
        expect(r.spec!.timing, leader.timing, reason: 'one table, one set of clocks');
      }
      for (final r in rooms) {
        r.dispose();
      }
    });
  });

  test('a start that names another house, or none, or says its clocks short of in full, is another build\'s; a build that names none sits at nothing', () {
    final timing = TableTiming.standard.toJson();
    final said = <(String?, Map<String, Object?>)>[
      (_house, {'timing': timing}),
      (_house, {'house': 'ab' * 32, 'timing': timing}),
      (_house, {'house': _house}),
      (_house, {'house': _house, 'timing': {...timing}..remove('silenceMs')}),
      (_house, {'house': _house, 'timing': {...timing, 'graceMs': 500}}),
      (_house, {'house': _house, 'timing': 'quick'}),
      // A build that names no house: a table it sat at would have none
      // to deal its bots, and no referee would take it.
      (null, {'timing': timing}),
      (null, {'house': _house, 'timing': timing}),
    ];
    for (final (ours, extra) in said) {
      fakeAsync((async) {
        final bus = Bus();
        int now() => async.elapsed.inMilliseconds;
        final ada = FakeSigner('Ada');
        final zed = FakeSigner('Zed');
        final room = Room(house: ours, canDeal: true, channel: bus.attach(ada), code: 'ROOM', myName: 'Ada', nowMs: now);
        async.elapse(const Duration(seconds: 1));
        bus.attach(zed).announce({
          'kind': 'start',
          'table': _table,
          'seed': 7,
          'seats': [
            {'key': ada.publicKey, 'name': 'Ada'},
            {'key': zed.publicKey, 'name': 'Zed'},
            {'bot': Persona.roster[0].id},
            {'bot': Persona.roster[1].id},
          ],
          'policy': botPolicyVersion,
          'sealed': true,
          'target': 50,
          'at': now(),
          ...extra,
        });
        async.elapse(const Duration(seconds: 1));
        expect(room.spec, isNull, reason: '$ours $extra');
        expect(room.refusal, RoomRefusal.otherBuild, reason: '$ours $extra');
        room.dispose();
      });
    }
  });

  test('a table started here names the house, and a build that names none starts nothing', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final rooms = [for (final n in ['Ada', 'Bao']) Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 14));
      for (final r in rooms) {
        expect(r.spec?.house, _house);
        expect(r.spec?.timing, TableTiming.standard);
        r.dispose();
      }
      final bare = Bus();
      final none = [for (final n in ['Ada', 'Bao']) Room(canDeal: true, channel: bare.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 30));
      expect(bare.stored.where((e) => (jsonDecode(e.content) as Map)['kind'] == 'start'), isEmpty);
      for (final r in none) {
        r.dispose();
      }
    });
  });

  test('a start without a table id of its own, or with a guessable one, is another build\'s', () {
    for (final id in <Object?>[null, 'ROOM-7-1', 'm1234abcd', '0123456789ABCDEF0123456789ABCDEF']) {
      fakeAsync((async) {
        final bus = Bus();
        int now() => async.elapsed.inMilliseconds;
        final ada = FakeSigner('Ada');
        final zed = FakeSigner('Zed');
        final room = Room(house: _house, canDeal: true, channel: bus.attach(ada), code: 'ROOM', myName: 'Ada', nowMs: now);
        async.elapse(const Duration(seconds: 1));
        bus.attach(zed).announce({
          ..._inFull,
          'kind': 'start',
          'table': ?id,
          'seed': 7,
          'seats': [
            {'key': ada.publicKey, 'name': 'Ada'},
            {'key': zed.publicKey, 'name': 'Zed'},
            {'bot': Persona.roster[0].id},
            {'bot': Persona.roster[1].id},
          ],
          'policy': botPolicyVersion,
          'sealed': true,
          'at': now(),
        });
        async.elapse(const Duration(seconds: 1));
        expect(room.spec, isNull, reason: '$id');
        expect(room.refusal, RoomRefusal.otherBuild, reason: '$id');
        room.dispose();
      });
    }
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
        final rooms = [for (final n in ['Ada', 'Bao', 'Cara', 'Dee']) Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner(n)), code: code, myName: n, nowMs: now)];
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
      final a = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      a.start();
      async.elapse(const Duration(seconds: 1));
      expect(a.spec, isNull, reason: 'alone');
      final b = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
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
      final a = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      final b = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
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
      final c = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
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

  test('the fourth to arrive is seated by the table its own arrival made', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final three = [for (final n in ['Ada', 'Bao', 'Cara']) Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner(n)), code: 'ROOM', myName: n, nowMs: now)];
      async.elapse(const Duration(seconds: 3));
      expect(three.every((r) => r.spec == null), isTrue, reason: 'three is not a table on its own');

      // The fourth opens the link. Beats are not stored, so it has
      // heard nobody yet, and its own first beat is what makes the
      // room four — which starts the table at once, from a device
      // whose beat has not come round again. Waiting for that beat is
      // waiting for a room everyone else has just left.
      final last = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('Dee')), code: 'ROOM', myName: 'Dee', nowMs: now);
      async.elapse(const Duration(seconds: 12));

      expect(three.every((r) => r.seated), isTrue, reason: 'the three are at it');
      expect(last.spec, isNotNull, reason: 'and so is the one that completed it');
      expect(last.seated, isTrue);
      expect(last.spec!.id, three.first.spec!.id, reason: 'the same table');
      for (final r in [...three, last]) {
        r.dispose();
      }
    });
  });

  test('a start is this room\'s when it seats me and the one who sent it, since I came in', () {
    fakeAsync((async) {
      int now() => async.elapsed.inMilliseconds;

      // Seats me and its sender, made since I came in: the table I am
      // at. The fourth to arrive gets exactly this, and gets it before
      // any beat of the sender's has come round again.
      final bus = Bus();
      final ada = FakeSigner('a');
      final b = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      bus.publish(NostrEvent.sign(ada, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': now(),
        'seats': [
          {'key': ada.publicKey, 'name': 'Ada'}, {'key': b.me, 'name': 'Bao'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 1));
      expect(b.spec, isNotNull, reason: 'the sender is at it too, and it is newer than my way in');
      expect(b.seated, isTrue);
      b.dispose();

      // Seats me and not the one who sent it: somebody putting me at a
      // table they are not at. Held for a beat that says they are at
      // least here, and dropped when none comes.
      final bus2 = Bus();
      final ghost = FakeSigner('ghost');
      final c = Room(house: _house, canDeal: true, channel: bus2.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      bus2.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': now(),
        'seats': [
          {'key': c.me, 'name': 'Cara'}, {'bot': 'Han'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 1));
      expect(c.spec, isNull, reason: 'held, not taken, until the sender is heard from');
      bus2.attach(ghost).announce({'kind': 'here', 'name': 'Ghost', 'seed': 1, 'since': now(), 'policy': botPolicyVersion}, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      expect(c.spec, isNotNull, reason: 'taken once they are here');
      c.dispose();

      final bus3 = Bus();
      final d = Room(house: _house, canDeal: true, channel: bus3.attach(FakeSigner('d')), code: 'ROOM', myName: 'Dee', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      bus3.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': now(),
        'seats': [
          {'key': d.me, 'name': 'Dee'}, {'bot': 'Han'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 9));
      bus3.attach(ghost).announce({'kind': 'here', 'name': 'Ghost', 'seed': 1, 'since': now(), 'policy': botPolicyVersion}, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      expect(d.spec, isNull, reason: 'and held only so long: a beat that never comes is nobody');
      d.dispose();

      // Older than my way into the room, whoever it seats: a table
      // that was played under this code and left, handed back by the
      // relay, and not one to sit down at again.
      final bus4 = Bus();
      final before = now();
      async.elapse(const Duration(seconds: 6));
      final e = Room(house: _house, canDeal: true, channel: bus4.attach(FakeSigner('e')), code: 'ROOM', myName: 'Eve', nowMs: now);
      async.elapse(const Duration(seconds: 1));
      bus4.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': before,
        'seats': [
          {'key': ghost.publicKey, 'name': 'Ghost'}, {'key': e.me, 'name': 'Eve'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 12));
      expect(e.spec, isNull, reason: 'it started before I was here');
      e.dispose();
    });
  });

  test('how you look travels with you: the icon and colour in every beat, the picture once, and all of it into the seats', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final picture = Uint8List.fromList(List.generate(200, (i) => (i * 7) % 256));
      final a = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', myAvatar: Avatar(icon: 'rocket', color: 3, picture: picture), nowMs: now);
      final b = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', myAvatar: const Avatar(icon: 'cake'), nowMs: now);
      async.elapse(const Duration(seconds: 3));
      final adaAtB = b.members.firstWhere((m) => m.name == 'Ada');
      expect(adaAtB.avatar, Avatar(icon: 'rocket', color: 3, picture: picture), reason: 'icon, colour and picture');
      expect(a.members.firstWhere((m) => m.name == 'Bao').avatar, const Avatar(icon: 'cake'));
      // A third arrives after the picture went by: the relay kept it.
      final c = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
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

  test('a picture inside another player\'s avatar is no picture: only one sent on its own is shown', () {
    fakeAsync((async) {
      final bus = Bus();
      int now() => async.elapsed.inMilliseconds;
      final hidden = base64Encode(Uint8List.fromList(List.generate(200, (i) => (i * 3) % 256)));
      final b = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
      final changed = FakeSigner('changed');
      async.elapse(const Duration(seconds: 1));
      // A changed app's beat, with a picture where the app never puts one.
      bus.attach(changed).announce({
        'kind': 'here', 'name': 'Mallory', 'seed': 1, 'since': now(), 'policy': botPolicyVersion,
        'avatar': {'icon': 'rocket', 'picture': hidden},
      }, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      final mallory = b.members.firstWhere((m) => m.name == 'Mallory');
      expect(mallory.avatar, const Avatar(icon: 'rocket'), reason: 'the icon, and no picture');
      b.dispose();
    });
  });

  test('every table a room starts is sealed, and a start that is not is not sat at', () {
    fakeAsync((async) {
      int now() => async.elapsed.inMilliseconds;

      // Two rooms that can deal: the start the leader makes says so.
      final bus = Bus();
      final said = <Map<String, Object?>>[];
      bus.attach(FakeSigner('watcher')).lobby.listen((e) {
        final c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
        if (c['kind'] == 'start') said.add(c);
      });
      final a = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      final b = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('b')), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 12));
      expect(said, isNotEmpty, reason: 'the leader started the table');
      expect(said.every((c) => c['sealed'] == true), isTrue, reason: 'every live table is sealed');
      expect(a.spec!.sealed, isTrue);
      a.dispose();
      b.dispose();

      // An unsealed start that seats this device — an older build's, or
      // one that could not run the deal and started anyway — is not
      // sat at: its cards could be read by anyone at the table.
      final bus2 = Bus();
      final ghost = FakeSigner('ghost');
      final c = Room(house: _house, canDeal: true, channel: bus2.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
      bus2.attach(ghost).announce({'kind': 'here', 'name': 'Ghost', 'seed': 1, 'since': now(), 'policy': botPolicyVersion}, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      bus2.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': false, 'at': now(),
        'seats': [
          {'key': ghost.publicKey, 'name': 'Ghost'}, {'key': c.me, 'name': 'Cara'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 1));
      expect(c.spec, isNull, reason: 'not a table this device sits at');
      expect(c.refusal, isNotNull, reason: 'and it says why');
      c.dispose();
    });
  });

  test('a device that cannot run the deal sits at no table, starts none, and says so', () {
    fakeAsync((async) {
      int now() => async.elapsed.inMilliseconds;
      final bus = Bus();
      final said = <Map<String, Object?>>[];
      bus.attach(FakeSigner('watcher')).lobby.listen((e) {
        final c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
        if (c['kind'] == 'start') said.add(c);
      });
      // The lowest key leads, so a device that cannot deal is given the
      // lead here: it is the one that would have started the table.
      final signers = [FakeSigner('0'), FakeSigner('1')]..sort((x, y) => x.publicKey.compareTo(y.publicKey));
      final lead = Room(house: _house, canDeal: false, channel: bus.attach(signers[0]), code: 'ROOM', myName: 'Ada', nowMs: now);
      final other = Room(house: _house, canDeal: true, channel: bus.attach(signers[1]), code: 'ROOM', myName: 'Bao', nowMs: now);
      async.elapse(const Duration(seconds: 12));
      expect(lead.refusal, RoomRefusal.noDeal, reason: 'said before any start');
      expect(said.where((c) => (c['seats'] as List).any((s) => (s as Map)['key'] == lead.me)), isEmpty,
          reason: 'and it started no table for itself to sit at');
      lead.dispose();

      // Handed a sealed start that seats it, it still does not sit.
      final ghost = FakeSigner('ghost');
      final bus2 = Bus();
      final c = Room(house: _house, canDeal: false, channel: bus2.attach(FakeSigner('c')), code: 'ROOM', myName: 'Cara', nowMs: now);
      bus2.attach(ghost).announce({'kind': 'here', 'name': 'Ghost', 'seed': 1, 'since': now(), 'policy': botPolicyVersion}, ephemeral: true);
      async.elapse(const Duration(seconds: 1));
      bus2.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': now(),
        'seats': [
          {'key': ghost.publicKey, 'name': 'Ghost'}, {'key': c.me, 'name': 'Cara'}, {'bot': 'Westley'}, {'bot': 'Romeo'},
        ],
      }), tags: const [['t', 'ROOM']]), ephemeral: false);
      async.elapse(const Duration(seconds: 1));
      expect(c.spec, isNull);
      expect(c.refusal, RoomRefusal.noDeal);
      c.dispose();
      other.dispose();
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
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': now() - 3600000,
        'seats': [
          {'key': ghost.publicKey, 'name': 'Ghost'}, {'bot': 'Westley'}, {'bot': 'Romeo'}, {'bot': 'Juliet'},
        ],
      }), tags: const [['t', 'ROOM']]));
      final a = Room(house: _house, canDeal: true, channel: bus.attach(FakeSigner('a')), code: 'ROOM', myName: 'Ada', nowMs: now);
      async.elapse(const Duration(seconds: 2));
      expect(a.spec, isNull);
      expect(a.members.length, 1);
      // And a recent one from someone not present: still not a table.
      bus.publish(NostrEvent.sign(ghost, kind: 4244, content: jsonEncode({
        ..._inFull, 'kind': 'start', 'table': _table, 'seed': 1, 'policy': botPolicyVersion, 'sealed': true, 'at': now(),
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
