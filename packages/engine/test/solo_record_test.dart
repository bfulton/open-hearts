
import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  test('a solo game round-trips through its record and replays to the same result', () {
    final seed = 42;
    final game = HeartsGame(seed: seed);
    final personas = ['', 'Romeo', 'Juliet', 'Cyrano'];
    final human = Bot(persona: Persona.westley);
    final bots = [for (var s = 0; s < seatCount; s++) s == 0 ? null : Bot(persona: Persona.named(personas[s]))];
    final record = SoloRecord(seed: seed, personas: personas);
    final played = <Card>{};
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          final pass = human.choosePass(game.handOf(0));
          record.passes.add(pass);
          for (var s = 0; s < seatCount; s++) {
            game.setPass(s, s == 0 ? pass : bots[s]!.choosePass(game.handOf(s)));
          }
          played.clear();
        case Phase.playing:
          if (game.pendingTrick != null) {
            game.collectTrick();
            break;
          }
          final seat = game.currentSeat!;
          final view = BotView(
            seat: seat,
            hand: game.handOf(seat),
            trick: game.trick,
            played: played,
            heartsBroken: game.heartsBroken,
            isFirstTrick: game.isFirstTrick,
            taken: game.taken,
          );
          final card = (seat == 0 ? human : bots[seat]!).chooseCard(view, game.legalPlaysFor(seat));
          if (seat == 0) record.plays.add(card);
          game.play(seat, card);
          played.add(card);
        case Phase.handOver:
          if (game.passDirection == PassDirection.hold) {}
          game.nextHand();
          if (game.passDirection == PassDirection.hold) record.passes.add(null);
          played.clear();
        case Phase.gameOver:
          break;
        case Phase.dealing:
          throw StateError('a seeded game deals itself');
      }
    }
    final text = record.encode();
    expect(text, startsWith('oh1:42:Romeo,Juliet,Cyrano:'));
    final back = SoloRecord.parse(text);
    expect(back, isNotNull);
    expect(back!.encode(), text);
    final replay = back.replay();
    expect(replay.complete, isTrue);
    expect(replay.game.totals, game.totals);
    expect(replay.hands.length, game.handNumber + 1);
  });

  test('a truncated or garbled record is refused or replays as far as it goes', () {
    expect(SoloRecord.parse('nonsense'), isNull);
    expect(SoloRecord.parse('oh1:1:Romeo,Juliet:::'), isNull);
    final r = SoloRecord.parse('oh1:7:Romeo,Juliet,Cyrano:2C.3C.4C:');
    expect(r, isNotNull);
    expect(r!.replay().complete, isFalse);
  });
}
