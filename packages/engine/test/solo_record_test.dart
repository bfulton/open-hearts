
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  test('a solo game round-trips through its record and replays to the same result', () {
    final seed = 42;
    final game = HeartsGame(seed: seed);
    final personas = ['', 'Romeo', 'Juliet', 'Cyrano'];
    final record = SoloRecord(seed: seed, personas: personas);
    _playRecorded(game, record, Bot(persona: Persona.westley));
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

  test('a game dealt from a deal seed round-trips through its record and replays to the same result', () {
    final seed = DealSeed.draw();
    final game = HeartsGame(dealSeed: seed);
    final record = SoloRecord(dealSeed: seed, personas: ['', 'Romeo', 'Juliet', 'Cyrano']);
    _playRecorded(game, record, Bot(persona: Persona.westley));
    final text = record.encode();
    expect(text, startsWith('oh2:${seed.hex}:Romeo,Juliet,Cyrano:'));
    final back = SoloRecord.parse(text);
    expect(back, isNotNull);
    expect(back!.seed, isNull);
    expect(back.dealSeed, seed);
    expect(back.encode(), text);
    final replay = back.replay();
    expect(replay.complete, isTrue);
    expect(replay.game.dealSeed, seed);
    expect(replay.game.totals, game.totals);
    expect(replay.hands.length, game.handNumber + 1);
    for (final h in replay.hands) {
      final deck = seed.deck(h.index);
      expect(h.dealt, [for (var s = 0; s < seatCount; s++) deck.sublist(s * 13, s * 13 + 13)..sort()],
          reason: 'hand ${h.index} as dealt is the seed\'s, and nothing else\'s');
    }
  });

  test('a record from before the deal seed replays exactly as it always did', () {
    // Made and replayed by the engine as it was before there was a deal
    // seed, the way the app made them: the bots drawn by Random from
    // the seed, one game to fifty and one to a hundred. Records like
    // these are on players' devices and pasted into issues; the log is
    // every trick, every pass and every hand's score.
    _expectReplay(
      'oh1:1733949467:Shah Jahan,Catherine,Westley:KS.10C.9C|10C.AS.QH|AS.KC.QC|-:'
      'KC,2D,6S,4D,8S,AS,2H,6D,JH,8D,KH,JD,AD,AD,4S,AH,6D,5S,3H,8H,8S,9D,6H,4H,QD,8D,2C,7S,4C,QS,6H,3H,4D,2H,6D,8D,9D,JD,QD,AC,'
      '5S,JC,7S,7D,8S,AH,3D,7C,AD,KD,6D,5D',
      totals: [27, 8, 54, 15],
      scores: [[20, 0, 1, 5], [0, 1, 24, 1], [3, 0, 16, 7], [4, 7, 13, 2]],
      log: 'a63f61f363572cb47b99fd6951a0dbe845be8f42c5d325d4283d8a13961bec2a',
    );
    _expectReplay(
      'oh1:905112306:Estella,Catherine,Romeo:AH.QD.10C|AS.QC.8C|AS.KH.8D|-|AS.AC.KC|QS.AH.AC|KC.9D.4D|-|KC.8C.7D|AC.KH.JD|KH.QH.KD:'
      '7C,4C,10H,2D,QS,7D,2S,AD,10D,KS,8S,4S,3S,4C,3D,5H,8S,KH,10S,6H,6D,9H,QD,10D,5D,6S,AC,3S,4D,6D,JH,6S,QH,7C,QS,KC,QC,9C,8C,QC,'
      '9C,3S,7D,4S,10D,10C,9H,4H,JC,KS,JS,10S,5C,KD,3S,AH,10H,4S,7H,6H,5D,JD,10D,8D,JS,KC,JS,4D,6S,KH,QC,JD,6D,3D,QH,5H,10H,3H,2C,AH,'
      '10D,3H,JD,4H,8S,KD,5S,KH,8H,5H,7S,2C,4S,10C,3D,7C,7S,AH,7H,5H,5D,2H,KD,JD,2C,AC,7S,QH,10S,JS,5H,6D,10H,5D,AD,6H,8H,10D,9D,3S,'
      '7D,QS,5D,2S,4H,AH,9H,6S,JS,9S,AC,5S,7S,2D,3H,10C,6C,AH,7D,JH,AD,9C,7C:100',
      totals: [39, 88, 103, 56],
      scores: [
        [5, 5, 15, 1], [0, 20, 5, 1], [9, 1, 16, 0], [0, 4, 22, 0], [4, 18, 0, 4], [0, 4, 0, 22], //
        [15, 2, 0, 9], [0, 4, 22, 0], [2, 6, 13, 5], [2, 17, 6, 1], [2, 7, 4, 13],
      ],
      log: '3da98a582fb696c1f0a5afd130f3c75c51e7a92a7986f57b005c4f90d23a25e0',
    );
  });

  test('a record with a deal seed replays to the same game wherever it is replayed', () {
    // The same on the VM and in a browser, and pinned: a change to how
    // a deal seed deals would change every game already kept.
    _expectReplay(
      'oh2:000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f:Romeo,Juliet,Cyrano:AS.6D.3D|KH.KC.10C|QS.6D.KH|-:'
      '2C,3C,KC,AH,KH,QH,8H,JC,4C,6C,8C,9C,10C,AC,5S,9S,8C,AD,KD,4D,JH,6D,7D,8D,8H,JD,AC,2S,JD,4S,4C,7S,8C,3H,4H,QC,6H,JC,QH,JC,'
      '5S,3C,6S,AD,4D,JS,9H,7D,4H,6D,10C,8C',
      totals: [27, 51, 45, 33],
      scores: [[0, 26, 26, 26], [25, 1, 0, 0], [2, 20, 4, 0], [0, 4, 15, 7]],
      log: '255e627f516967c2b7cf02db26386cf8ef7bb8497b20910237e78bc2db4c8437',
    );
    _expectReplay(
      'oh2:ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100:Buttercup,Estella,Shah Jahan:'
      'KS.KD.7D|AH.QH.KC|QS.KS.AC|-|KS.10D.2D|AH.KH.9D|2C.KS.QS|-|AS.KH.QH|AS.AH.QH|KS.KC.JC|-:'
      '2C,6C,6S,9S,2H,7C,5H,8C,10H,JH,QH,AC,AH,JC,9C,2S,KH,3S,AD,2D,10D,9D,6D,9S,8S,7S,QC,5S,AD,10S,10C,8D,10H,7H,9H,6H,KD,9D,QD,QC,'
      'JD,4C,9S,2D,4S,4H,7H,5D,2H,3S,AD,2S,2C,8S,4C,6C,AS,3H,7H,AH,QC,4D,4H,KH,AC,2C,KC,2D,3S,6C,3H,3D,KS,5H,8H,10H,QC,AD,KD,9S,'
      '10H,8H,8S,JD,4S,6D,5D,4D,2D,6H,7H,AC,3C,4S,AS,4C,5D,6H,7D,10D,8D,KC,QC,JC,AC,8S,3D,5D,2H,AH,10D,9D,4D,QC,JC,9C,8C,AC,3C,3D,'
      'KH,4H,4D,JH,6H,8D,AD,5H,9C,10C,3C,QS,JS,KH,7H,7D,8H,9H,4D,3D,9S,4S,3S,2C,4S,8S,QH,8H,5H,6D,6C,2D,QD,3C,9C,10D:100',
      totals: [63, 99, 106, 44],
      scores: [
        [20, 0, 6, 0], [5, 19, 1, 1], [0, 13, 9, 4], [0, 18, 4, 4], [0, 0, 7, 19], [18, 4, 1, 3], //
        [2, 4, 20, 0], [17, 3, 5, 1], [0, 17, 4, 5], [0, 10, 16, 0], [0, 7, 13, 6], [1, 4, 20, 1],
      ],
      log: '9eb63f72be88a89f6c14e11297777c200fe20e26d33a46d0b179e03b1a92f11e',
    );
  });

  test('a game to another target says so, and replays to it', () {
    final record = SoloRecord(seed: 42, personas: ['', 'Romeo', 'Juliet', 'Cyrano'], target: longGameScore);
    final text = record.encode();
    expect(text, endsWith(':$longGameScore'), reason: 'the target rides at the end');
    final back = SoloRecord.parse(text);
    expect(back, isNotNull);
    expect(back!.target, longGameScore);
    expect(back.replay().game.target, longGameScore);
    // A game to fifty is the line it always was, and one from before
    // there was anything to say replays to fifty.
    expect(SoloRecord(seed: 42, personas: ['', 'Romeo', 'Juliet', 'Cyrano']).encode(), endsWith(':'));
    expect(SoloRecord.parse('oh1:7:Romeo,Juliet,Cyrano:2C.3C.4C:')!.target, gameOverScore);
  });

  test('a truncated or garbled record is refused or replays as far as it goes', () {
    expect(SoloRecord.parse('nonsense'), isNull);
    expect(SoloRecord.parse('oh1:1:Romeo,Juliet:::'), isNull);
    final r = SoloRecord.parse('oh1:7:Romeo,Juliet,Cyrano:2C.3C.4C:');
    expect(r, isNotNull);
    expect(r!.replay().complete, isFalse);

    // Each version's seed is its own.
    final hex = DealSeed([for (var i = 0; i < 32; i++) i]).hex;
    expect(SoloRecord.parse('oh2:$hex:Romeo,Juliet,Cyrano::')?.dealSeed?.hex, hex);
    expect(SoloRecord.parse('oh2:7:Romeo,Juliet,Cyrano::'), isNull);
    expect(SoloRecord.parse('oh2:${hex.substring(2)}:Romeo,Juliet,Cyrano::'), isNull);
    expect(SoloRecord.parse('oh1:$hex:Romeo,Juliet,Cyrano::'), isNull);
    expect(SoloRecord.parse('oh3:$hex:Romeo,Juliet,Cyrano::'), isNull);
    expect(() => SoloRecord(personas: ['', 'Romeo', 'Juliet', 'Cyrano']), throwsArgumentError);
    expect(() => SoloRecord(seed: 7, dealSeed: DealSeed.draw(), personas: ['', 'Romeo', 'Juliet', 'Cyrano']), throwsArgumentError);
  });
}

/// Plays [game] to its end as the app does, [human]'s choices taken
/// down in [record].
void _playRecorded(HeartsGame game, SoloRecord record, Bot human) {
  final bots = [for (var s = 0; s < seatCount; s++) s == 0 ? null : Bot(persona: Persona.named(record.personas[s]))];
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
        game.nextHand();
        if (game.passDirection == PassDirection.hold) record.passes.add(null);
        played.clear();
      case Phase.gameOver:
        break;
      case Phase.dealing:
        throw StateError('a seeded game deals itself');
    }
  }
}

/// Replays [text] and checks it against what it replayed to when it was
/// made: the totals, each hand's score, and a hash of [_log].
void _expectReplay(String text, {required List<int> totals, required List<List<int>> scores, required String log}) {
  final record = SoloRecord.parse(text);
  expect(record, isNotNull, reason: text);
  expect(record!.encode(), text, reason: 'the line reads back as it was written');
  final replay = record.replay();
  expect(replay.complete, isTrue);
  expect(replay.game.totals, totals);
  expect([for (final h in replay.hands) h.scores], scores);
  expect(sha256.convert(utf8.encode(_log(replay))).toString(), log);
}

/// Every hand of [replay] as a line: its number, its scores, who shot
/// the moon, the human's pass, and every trick, seat by card.
String _log(Replay replay) => [
      for (final h in replay.hands)
        '${h.index} ${h.scores.join(',')} ${h.moonShooter ?? '-'} ${h.humanPass.map((c) => c.code).join('.')} '
            '${h.tricks.map((t) => t.map((p) => '${p.seat}${p.card.code}').join('.')).join('/')}'
    ].join('\n');
