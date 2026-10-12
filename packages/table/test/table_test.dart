import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';


void main() {
  test('events round-trip and refuse a bad signature', () {
    final me = FakeSigner('me');
    final e = TableEvent.sign(me, table: 't', kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 0, 'card': '2C'});
    final back = TableEvent.parse(e.toJson());
    expect(back, isNotNull);
    expect(back!.id, e.id);
    final forged = Map<String, Object?>.from(e.toJson())..['body'] = {'hand': 0, 'turn': 4, 'seat': 0, 'card': 'QS'};
    expect(TableEvent.parse(forged), isNull);
    final real = SchnorrSigner.generate();
    final r = TableEvent.sign(real, table: 't', kind: EventKind.heartbeat, body: {'hand': 0, 'step': 0});
    expect(TableEvent.parse(r.toJson()), isNotNull);
  });

  test('a spec carries the score the game runs to; one from a build that had no say runs to fifty', () {
    final spec = TableSpec(
      id: 't',
      seed: 1,
      seats: [HumanSeat(FakeSigner('me').publicKey), for (var s = 1; s < seatCount; s++) BotSeat(Persona.roster[s])],
      target: longGameScore,
    );
    expect(TableSpec.parse(spec.toJson())!.target, longGameScore);
    expect(HeartsGame(seed: spec.seed, target: spec.target).target, longGameScore);
    final older = Map<String, Object?>.from(spec.toJson())..remove('target');
    expect(TableSpec.parse(older)!.target, gameOverScore);
  });

  for (final humans in [1, 2, 3, 4]) {
    test('$humans human(s) and ${4 - humans} bot(s) play a whole game and agree on it', () {
      final t = SimTable(humans: humans, seed: 7);
      t.start();
      expect(t.run(), isTrue, reason: 'every client reaches the end of the game');
      final records = [for (final c in t.clients) c.record.map((d) => d.key).toList()];
      for (final r in records) {
        expect(r, records.first, reason: 'every client holds the same record');
      }
      final totals = [for (final c in t.clients) c.game.totals];
      for (final s in totals) {
        expect(s, totals.first);
      }
      final v = verifyRecord(t.spec, t.clients.first.record, juries: t.clients.first.juries);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.winners, t.clients.first.game.winners);
      expect(v.ratings.length, humans);
      expect(t.clients.first.pause, isNull);
      t.stop();
    });
  }
}
