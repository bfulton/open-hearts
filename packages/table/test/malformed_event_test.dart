/// A signed event whose body is not its kind's shape is dropped like
/// any malformed event: a client of another build, or one that lies, can
/// sign anything, and nothing past the parser may meet a field that is
/// missing or of the wrong type. One the referee logged anyway is an
/// entry that changes nothing, at every side alike (log.dart).
library;

import 'package:engine/engine.dart' show Phase;
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  final me = FakeSigner('me');
  Map<String, Object?> signed(EventKind kind, Map<String, Object?> body, {String table = 't'}) =>
      TableEvent.sign(me, table: table, kind: kind, body: body).toJson();
  TableEvent? parsed(EventKind kind, Map<String, Object?> body) => TableEvent.parse(signed(kind, body));

  test('the parser keeps an event of its kind\'s shape and drops one that is not', () {
    expect(parsed(EventKind.play, {'hand': 0, 'turn': 4, 'seat': 0, 'card': '2C'}), isNotNull);
    expect(parsed(EventKind.play, {'hand': 0, 'turn': 4, 'seat': 0}), isNull, reason: 'no card');
    expect(parsed(EventKind.play, {'hand': 0, 'turn': '4', 'seat': 0, 'card': '2C'}), isNull, reason: 'a turn of text');
    expect(parsed(EventKind.start, {'spec': 'a table'}), isNull, reason: 'a spec that is no map');
    expect(parsed(EventKind.deal, {'hand': 0, 'turn': -16, 'seat': 0}), isNull, reason: 'no round');
    expect(parsed(EventKind.pass, {'hand': 0, 'turn': 0, 'seat': 0, 'cards': [1, 2, 3]}), isNull, reason: 'cards that are not cards');
    expect(parsed(EventKind.leave, {}), isNull, reason: 'no seat');
    expect(parsed(EventKind.release, {'hand': 0}), isNull, reason: 'about nobody');
    expect(parsed(EventKind.result, {'n': 9, 'hash': 'x', 'state': 'finished', 'totals': ['1']}), isNull, reason: 'totals of text');
    expect(parsed(EventKind.result, {'n': 9, 'hash': 'x', 'totals': [1, 2, 3, 4]}), isNull, reason: 'no state');
  });

  test('an event reads with its own id whatever order its maps\' keys come back in, at any depth', () {
    // A lone player's audit names the departed seats' secrets by seat,
    // in the order they went (DealSession.myAudit); the referee hands it
    // back written from a JavaScript object, which puts "0" ahead of "2"
    // ahead of "3" whatever order they came in.
    final made = TableEvent.sign(me, table: 't', kind: EventKind.deal, body: {
      'hand': 1,
      'turn': TurnId.audit(1, 1).index,
      'seat': 1,
      'round': 4,
      'secret': 's',
      'known': {'3': 'c', '0': 'a', '2': 'b'},
      'deeper': [
        {'10': 'x', '9': 'y', 'b': 'z', 'a': 'w'},
      ],
    });
    final back = asJavaScriptHoldsIt(made.toJson()) as Map<String, Object?>;
    expect(((back['body'] as Map)['known'] as Map).keys, ['0', '2', '3'], reason: 'the order changed on the way');
    final read = TableEvent.parse(back);
    expect(read, isNotNull);
    expect(read!.id, made.id);
    // And reads as itself in a log, not as an entry that changes nothing.
    final entry = LogEntry.parse({'n': 9, 't': 1000, 'e': back})!;
    expect(entry.event?.id, made.id);
    expect(entry.unread, isNull);
  });

  test('an event nested deeper than any build writes one is dropped by the parser, not thrown out of it', () {
    Object? lists(int n) {
      Object? x = 0;
      for (var i = 0; i < n; i++) {
        x = [x];
      }
      return x;
    }

    // The event and its body are two deep, so thirty more is as deep as
    // one may go.
    Map<String, Object?> play(int n) => signed(EventKind.play, {'hand': 0, 'turn': 4, 'seat': 0, 'card': '2C', 'x': lists(n)});
    expect(TableEvent.parse(play(30)), isNotNull);
    expect(TableEvent.parse(play(31)), isNull);
    // Deep enough to overflow the stack of anything that walks it: too
    // deep to sign, so put together by hand.
    final deep = {...play(0), 'body': {'hand': 0, 'turn': 4, 'seat': 0, 'card': '2C', 'x': lists(10000)}};
    expect(TableEvent.parse(deep), isNull);
    final e = LogEntry.parse({'n': 3, 't': 1000, 'e': deep});
    expect(e, isNotNull, reason: 'an entry that changes nothing, not one the log cannot go past');
    expect(e!.event, isNull);
    expect(e.digestInput, '3|1000|e|${deep['id']}');
  });

  test('a log entry carrying one is kept as it came, by its id', () {
    final raw = signed(EventKind.play, {'hand': 0, 'turn': 4, 'seat': 0});
    final e = LogEntry.parse({'n': 3, 't': 1000, 'e': raw}, verifySignature: false)!;
    expect(e.event, isNull);
    expect(e.unread, raw);
    expect(e.isTick, isFalse);
    expect(e.digestInput, '3|1000|e|${raw['id']}');
    expect(e.toJson()['e'], raw);
    expect(LogEntry.parse({'n': 3, 't': 1000, 'e': {...raw, 'id': 'not an id'}}, verifySignature: false), isNull,
        reason: 'the referee takes none that does not name its id');
  });

  test('a person who puts malformed events in the log mid-hand does not stop the table', () {
    final t = SimTable(humans: 4, seed: 7);
    t.start();
    t.clock.runUntil(() => t.clients.first.started && t.clients.first.game.phase == Phase.playing, limitMs: 10 * 60 * 1000);
    final liar = t.signers.first;
    final hand = t.clients.first.game.handNumber;
    for (final (kind, body) in <(EventKind, Map<String, Object?>)>[
      (EventKind.play, {'hand': hand, 'turn': TurnId.passTurns, 'seat': 0}),
      (EventKind.leave, {'hand': hand}),
      (EventKind.result, {'n': 1, 'hash': 'x', 'state': 'finished'}),
      (EventKind.release, {'hand': hand, 'about': 'everyone'}),
    ]) {
      t.referee.receiveUnread(TableEvent.sign(liar, table: t.spec.id, kind: kind, body: body).toJson(), liar.publicKey);
    }
    expect(t.referee.log.where((e) => e.unread != null), hasLength(4), reason: 'in the log');
    expect(t.run(), isTrue, reason: 'every game finished');
    final ends = {for (final c in t.clients) '${c.rules.endHash} ${c.game.totals}'};
    expect(ends, hasLength(1), reason: 'and every side came to the same end');
    expect(t.clients.first.rules.removals, isEmpty, reason: 'nobody was removed by it');
    t.close();
  });
}
