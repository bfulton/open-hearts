/// Quick reactions (reactions.dart): what one is on the wire, and the
/// rules every screen holds everyone else's to — said by a seat held in
/// person, a code it knows, lately, about this hand or the next one
/// over, once, and no faster than one every few seconds.
library;

import 'package:engine/engine.dart' show Phase;
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  final ada = FakeSigner('ada').publicKey;
  final bao = FakeSigner('bao').publicKey;
  final stranger = FakeSigner('stranger').publicKey;
  final seated = {ada: 0, bao: 2};

  // Milliseconds since the epoch, as a screen tells the time.
  var now = 1800000000000;
  int nowS() => now ~/ 1000;
  late ReactionRules rules;
  var ids = 0;
  setUp(() {
    rules = ReactionRules(now: () => now);
  });

  HeardReaction heard(PublicKey from, String content, {int? at, String? id}) =>
      (from: from, id: id ?? 'e${ids++}', createdAt: at ?? nowS(), content: content);
  String said(Reaction r, {int hand = 3, int turn = 12}) => ReactionSaid(r, hand: hand, turn: turn).encode();

  group('on the wire', () {
    test('a code and the moment it was said at, and nothing else', () {
      final content = said(Reaction.nice, hand: 2, turn: 17);
      expect(content, '{"react":"nice","hand":2,"turn":17}');
      final back = ReactionSaid.decode(content)!;
      expect(back.reaction, Reaction.nice);
      expect(back.hand, 2);
      expect(back.turn, 17);
      expect(content.length, lessThan(ReactionSaid.most));
    });

    test('the codes are the wire format: fixed, short, and never words to show', () {
      expect([for (final r in Reaction.values) r.code], ['nice', 'ha', 'wow', 'ouch', 'sorry', 'gg']);
      expect([for (final r in Reaction.values) r.emoji], ['👍', '😂', '😮', '😬', '🙏', '👋']);
      for (final r in Reaction.values) {
        expect(Reaction.byCode(r.code), r);
        expect(r.code, matches(RegExp(r'^[a-z]{1,16}$')), reason: 'what the relay lets through (service/do/relay.mjs)');
      }
      expect(Reaction.byCode('lol'), isNull);
      expect(Reaction.byCode(null), isNull);
    });

    test('anything else is not a reaction', () {
      for (final content in [
        '',
        'nice',
        '["nice",3,12]',
        '{"react":"nice","hand":3}',
        '{"react":"nice","hand":3,"turn":12,"text":"hello"}',
        '{"react":"lol","hand":3,"turn":12}',
        '{"react":"Nice","hand":3,"turn":12}',
        '{"react":"nice","hand":"3","turn":12}',
        '{"react":"nice","hand":-1,"turn":12}',
        '{"react":"nice","hand":3,"turn":53}',
        '{"react":"nice","hand":3,"turn":1.5}',
        '{"react":"nice","hand":3,"turn":12}${' ' * ReactionSaid.most}',
      ]) {
        expect(ReactionSaid.decode(content), isNull, reason: content);
      }
    });
  });

  group('who is shown', () {
    test('a seat held in person, at its seat', () {
      expect(rules.hear(heard(ada, said(Reaction.ouch)), seated: seated, hand: 3), (seat: 0, reaction: Reaction.ouch));
      expect(rules.hear(heard(bao, said(Reaction.gg)), seated: seated, hand: 3), (seat: 2, reaction: Reaction.gg));
    });

    test('nobody else: a key not seated here — a stranger, a watcher, a bot\'s seat, a person since removed', () {
      expect(rules.hear(heard(stranger, said(Reaction.nice)), seated: seated, hand: 3), isNull);
      // Ada's seat has gone to a bot: her key is no longer among the
      // seated, and what she says is nobody's to show.
      expect(rules.hear(heard(ada, said(Reaction.nice)), seated: {bao: 2}, hand: 3), isNull);
    });

    test('only what this side knows: an unknown code, or anything not a reaction, is nothing', () {
      expect(rules.hear(heard(ada, '{"react":"lol","hand":3,"turn":12}'), seated: seated, hand: 3), isNull);
      expect(rules.hear(heard(ada, 'hello everyone'), seated: seated, hand: 3), isNull);
      // And it did not use up her turn to say something.
      expect(rules.hear(heard(ada, said(Reaction.wow)), seated: seated, hand: 3), isNotNull);
    });
  });

  group('when', () {
    test('lately: older than ten seconds is a moment gone, and as far ahead is a clock that is wrong', () {
      expect(rules.hear(heard(ada, said(Reaction.nice), at: nowS() - 11), seated: seated, hand: 3), isNull);
      expect(rules.hear(heard(bao, said(Reaction.nice), at: nowS() + 11), seated: seated, hand: 3), isNull);
      expect(rules.hear(heard(ada, said(Reaction.nice), at: nowS() - 9), seated: seated, hand: 3), isNotNull);
      expect(rules.hear(heard(bao, said(Reaction.nice), at: nowS() + 2), seated: seated, hand: 3), isNotNull);
    });

    test('about this hand, or the one either side of it: a screen a hand behind the table still shows it', () {
      expect(rules.hear(heard(ada, said(Reaction.ha, hand: 1)), seated: seated, hand: 3), isNull);
      expect(rules.hear(heard(ada, said(Reaction.ha, hand: 5)), seated: seated, hand: 3), isNull);
      expect(rules.hear(heard(ada, said(Reaction.ha, hand: 4)), seated: seated, hand: 3), isNotNull);
      now += 3000;
      expect(rules.hear(heard(ada, said(Reaction.ha, hand: 2)), seated: seated, hand: 3), isNotNull);
    });

    test('once: the same event by two relays, or said again by somebody else, is shown the first time', () {
      final e = heard(ada, said(Reaction.sorry), id: 'same');
      expect(rules.hear(e, seated: seated, hand: 3), isNotNull);
      now += 5000;
      expect(rules.hear(e, seated: seated, hand: 3), isNull);
    });
  });

  group('how often', () {
    test('a player says one at most every three seconds', () {
      expect(rules.maySay, isTrue);
      expect(rules.say(Reaction.nice, hand: 0, turn: 0), isNotNull);
      expect(rules.maySay, isFalse);
      now += 2999;
      expect(rules.say(Reaction.wow, hand: 0, turn: 0), isNull);
      now += 1;
      expect(rules.maySay, isTrue);
      expect(ReactionSaid.decode(rules.say(Reaction.wow, hand: 0, turn: 4)!)!.reaction, Reaction.wow);
    });

    test('a screen shows no faster than that, whatever a device says: a little slack for the wire, and each seat its own', () {
      expect(rules.hear(heard(ada, said(Reaction.nice)), seated: seated, hand: 3), isNotNull);
      now += 1000;
      expect(rules.hear(heard(ada, said(Reaction.wow)), seated: seated, hand: 3), isNull, reason: 'a second later');
      expect(rules.hear(heard(bao, said(Reaction.wow)), seated: seated, hand: 3), isNotNull, reason: 'somebody else');
      // Two said exactly three seconds apart arrive a little closer
      // than that, and both are shown.
      now += 1500 + 100;
      expect(rules.hear(heard(ada, said(Reaction.ouch)), seated: seated, hand: 3), isNotNull);
      // A flood is one shown every two and a half seconds at most.
      var shown = 0;
      for (var i = 0; i < 100; i++) {
        now += 100;
        if (rules.hear(heard(ada, said(Reaction.ha)), seated: seated, hand: 3) != null) shown++;
      }
      expect(shown, 4);
    });
  });

  group('who may react, for a watcher', () {
    test('a view names the keys its seats are held by, and only the seats held in person', () {
      final t = SimTable(humans: 2, seed: 3);
      t.start();
      final view = WatchedTable.of(t.people.first.client, const ['Ada', 'Romeo', 'Bao', 'Juliet']);
      t.stop();
      final keys = [for (final h in t.spec.seats) h is HumanSeat ? h.key : null];
      expect(view.keys, keys);
      expect(view.keys!.whereType<String>(), hasLength(2));
      expect(view.seated, {for (final (s, k) in keys.indexed) if (k != null) k: s});
      final back = WatchedTable.parse(view.toJson(), table: view.table)!;
      expect(back.keys, keys);
      expect(back.seated, view.seated);
    });

    test('a view that says no keys has nobody to react; one whose keys are not keys is not a view', () {
      final view = WatchedTable(
        table: 't',
        target: 50,
        seq: 1,
        hand: 0,
        phase: Phase.passing,
        names: const ['A', 'B', 'C', 'D'],
        totals: const [0, 0, 0, 0],
        taken: const [0, 0, 0, 0],
        plays: const [],
      );
      final json = view.toJson();
      expect(json.containsKey('keys'), isFalse);
      expect(WatchedTable.parse(json, table: 't')!.seated, isEmpty);
      expect(WatchedTable.parse({...json, 'keys': [ada, null, bao]}, table: 't'), isNull);
      expect(WatchedTable.parse({...json, 'keys': ['not a key', null, null, null]}, table: 't'), isNull);
      expect(WatchedTable.parse({...json, 'keys': [ada, null, bao, null]}, table: 't')!.seated, {ada: 0, bao: 2});
    });
  });

  test('a hub carries what one lane says to every other, and never back to the sayer', () async {
    final hub = ReactionHub(nowMs: () => now);
    final a = hub.lane(ada);
    final b = hub.lane(bao);
    final w = hub.lane(stranger);
    final heardByA = <HeardReaction>[];
    a.reactions.listen(heardByA.add);
    final byB = b.reactions.first;
    final byW = w.reactions.first;
    a.sayReaction(said(Reaction.nice));
    expect((await byB).from, ada);
    expect((await byW).content, said(Reaction.nice));
    expect((await byW).createdAt, nowS());
    await Future<void>.delayed(Duration.zero);
    expect(heardByA, isEmpty);
    hub.close();
  });
}
