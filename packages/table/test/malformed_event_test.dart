/// A signed event whose body is not its kind's shape is dropped like
/// any malformed event: a peer of another build, or one that lies, can
/// sign anything, and nothing past the parser may meet a field that is
/// missing or of the wrong type.
library;

import 'package:engine/engine.dart' show Phase;
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('the parser keeps an event of its kind\'s shape and drops one that is not', () {
    final me = FakeSigner('me');
    TableEvent? parsed(EventKind kind, Map<String, Object?> body) =>
        TableEvent.parse(TableEvent.sign(me, table: 't', kind: kind, body: body).toJson());
    expect(parsed(EventKind.play, {'hand': 0, 'turn': 4, 'seat': 0, 'card': '2C'}), isNotNull);
    expect(parsed(EventKind.play, {'hand': 0, 'turn': 4, 'seat': 0}), isNull, reason: 'no card');
    expect(parsed(EventKind.play, {'hand': 0, 'turn': '4', 'seat': 0, 'card': '2C'}), isNull, reason: 'a turn of text');
    expect(parsed(EventKind.heartbeat, {'hand': 0}), isNull, reason: 'no step');
    expect(parsed(EventKind.witness, {'hand': 0, 'turn': 4, 'seat': 0}), isNull, reason: 'nothing witnessed');
    expect(parsed(EventKind.jury, {'hand': 0, 'turn': -16, 'seat': 0, 'jurors': 'x', 'snapshot': []}), isNull,
        reason: 'jurors not a list');
    expect(parsed(EventKind.verdict, {'hand': 0, 'turn': 4, 'seat': 0, 'side': 'action', 'event': 'x'}), isNull,
        reason: 'the event ruled on not an event');
    expect(parsed(EventKind.ended, {'hand': 0, 'turn': 59, 'seat': 0, 'vote': 'yes'}), isNull, reason: 'a vote of text');
    expect(parsed(EventKind.topup, {'hand': 0, 'about': 2, 'at': 5, 'have': ['1']}), isNull, reason: 'have of text');
  });

  test('a peer that signs malformed events mid-hand does not stop the table', () {
    final t = SimTable(humans: 4, seed: 7);
    t.start();
    // Into the play, then the first seat's own key signs a run of
    // events of the wrong shape and says them to everyone.
    t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 10 * 60 * 1000);
    final liar = t.signers.first;
    final sender = t.clients.first.transport;
    final hand = t.clients.first.game.handNumber;
    for (final (kind, body) in <(EventKind, Map<String, Object?>)>[
      (EventKind.heartbeat, {'hand': hand}),
      (EventKind.play, {'hand': hand, 'turn': TurnId.passTurns, 'seat': 0}),
      (EventKind.witness, {'hand': hand, 'turn': TurnId.passTurns, 'seat': 0}),
      (EventKind.leave, {'hand': hand}),
      (EventKind.boot, {'hand': hand, 'turn': TurnId.passTurns, 'seat': '1'}),
      (EventKind.ended, {'hand': hand, 'turn': TurnId.passTurns, 'seat': 0}),
    ]) {
      sender.broadcast(TableEvent.sign(liar, table: t.spec.id, kind: kind, body: body).toJson(), everywhere: true);
    }
    expect(t.run(), isTrue, reason: 'every game finished');
    final scores = {for (final c in t.clients) c.game.totals.join(',')};
    expect(scores, hasLength(1), reason: 'and every side agrees on the score');
    t.stop();
  });
}
