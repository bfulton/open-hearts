/// A solo game, small enough to paste.
///
/// Everything a bot does is a consequence of the deal and the human's
/// choices, so a game against bots is fully described by its seed, who
/// sat where, and what the human passed and played. That is the record
/// the app keeps on the device and what its Copy button hands over —
/// a line of text that `replay` turns back into every trick, so a hand
/// where the moon got through can be studied and the defence tuned
/// against it.
///
/// Two versions, by the seed. `oh2` carries a [DealSeed], 256 bits as 64
/// hex digits: what the app deals from. `oh1` carries an int for
/// `dart:math`'s `Random`, and replays from it.
library;

import 'bot.dart';
import 'card.dart';
import 'deal_seed.dart';
import 'game.dart';
import 'persona.dart';
import 'rules.dart';

class SoloRecord {
  /// A record of a game dealt from [dealSeed], or by `Random` from
  /// [seed]: one of the two, never both.
  SoloRecord({this.seed, this.dealSeed, required this.personas, this.target = gameOverScore}) {
    if ((seed == null) == (dealSeed == null)) throw ArgumentError('a record names one seed: an int or a deal seed');
  }

  /// The version of a record whose seed is an int: a game dealt by
  /// `Random`.
  static const randomVersion = 'oh1';

  /// The version of a record whose seed is a [DealSeed].
  static const dealSeedVersion = 'oh2';

  String get version => dealSeed == null ? randomVersion : dealSeedVersion;

  /// The int an `oh1` game was dealt from; null in `oh2`.
  final int? seed;

  /// The seed an `oh2` game was dealt from; null in `oh1`.
  final DealSeed? dealSeed;

  /// The score the game ran to. The field is only written when the
  /// table asked for another target, so a game to fifty has no field.
  final int target;

  /// Persona name per seat; the human's seat ([humanSeat]) holds an
  /// empty string.
  final List<String> personas;

  /// The human's three passed cards per hand, or null on a hold hand.
  final List<List<Card>?> passes = [];

  /// The human's plays, in order, across every hand.
  final List<Card> plays = [];

  /// `oh2:seed:west,north,east:pass|pass|-|…:play,play,…`, and the
  /// target after it at a table that did not play to fifty. `oh1` is
  /// the same line with an int for the seed.
  String encode() => [
        version,
        dealSeed?.hex ?? seed.toString(),
        [for (var s = 0; s < personas.length; s++) if (s != humanSeat) personas[s]].join(','),
        [for (final p in passes) p == null ? '-' : p.map((c) => c.code).join('.')].join('|'),
        plays.map((c) => c.code).join(','),
        if (target != gameOverScore) target.toString(),
      ].join(':');

  static SoloRecord? parse(String text) {
    final parts = text.trim().split(':');
    if (parts.length != 5 && parts.length != 6) return null;
    if (parts[0] != randomVersion && parts[0] != dealSeedVersion) return null;
    try {
      final seed = parts[0] == randomVersion ? int.parse(parts[1]) : null;
      final dealSeed = parts[0] == dealSeedVersion ? DealSeed.tryParse(parts[1]) : null;
      if (seed == null && dealSeed == null) return null;
      final bots = parts[2].split(',');
      if (bots.length != seatCount - 1) return null;
      final personas = <String>[];
      var b = 0;
      for (var s = 0; s < seatCount; s++) {
        personas.add(s == humanSeat ? '' : bots[b++]);
      }
      for (final name in personas) {
        if (name.isNotEmpty) Persona.named(name); // throws when unknown
      }
      final r = SoloRecord(
          seed: seed, dealSeed: dealSeed, personas: personas, target: parts.length == 6 ? int.parse(parts[5]) : gameOverScore);
      if (parts[3].isNotEmpty) {
        for (final p in parts[3].split('|')) {
          r.passes.add(p == '-' ? null : [for (final c in p.split('.')) Card.parse(c)]);
        }
      }
      if (parts[4].isNotEmpty) {
        for (final c in parts[4].split(',')) {
          r.plays.add(Card.parse(c));
        }
      }
      return r;
    } catch (_) {
      return null;
    }
  }

  /// Replays the record through a fresh game. Stops where the record
  /// stops; [Replay.complete] says whether that was the end of the game.
  Replay replay() {
    final game = HeartsGame(seed: seed, dealSeed: dealSeed, target: target);
    final bots = [
      for (var s = 0; s < seatCount; s++)
        s == humanSeat ? null : Bot(persona: Persona.named(personas[s])),
    ];
    final hands = <ReplayedHand>[];
    var handIndex = 0;
    var playIndex = 0;
    var tricks = <List<Play>>[];
    var passed = <Card>[];
    var dealt = _dealt(game);
    while (game.phase != Phase.gameOver) {
      switch (game.phase) {
        case Phase.passing:
          final pass = handIndex < passes.length ? passes[handIndex] : null;
          if (pass == null) return Replay(hands, game, complete: false);
          final hand = game.handOf(humanSeat);
          if (pass.length != passSize || pass.toSet().length != passSize || !pass.every(hand.contains)) {
            return Replay(hands, game, complete: false);
          }
          passed = pass;
          for (var s = 0; s < seatCount; s++) {
            game.setPass(s, s == humanSeat ? pass : bots[s]!.choosePass(game.handOf(s)));
          }
        case Phase.playing:
          if (game.pendingTrick != null) {
            tricks.add(game.pendingTrick!.plays);
            game.collectTrick();
            break;
          }
          final seat = game.currentSeat!;
          final Card card;
          if (seat == humanSeat) {
            if (playIndex >= plays.length) return Replay(hands, game, complete: false);
            card = plays[playIndex++];
            if (!game.legalPlaysFor(seat).contains(card)) return Replay(hands, game, complete: false);
          } else {
            card = bots[seat]!.chooseCard(BotView.of(game, seat), game.legalPlaysFor(seat));
          }
          game.play(seat, card);
        case Phase.handOver:
          hands.add(ReplayedHand(handIndex, List.of(tricks), game.handScores, game.moonShooter, passed, dealt));
          tricks = [];
          passed = [];
          handIndex++;
          game.nextHand();
          dealt = _dealt(game);
        case Phase.gameOver:
          break;
        case Phase.dealing:
          throw StateError('a seeded game deals itself');
      }
    }
    hands.add(ReplayedHand(handIndex, List.of(tricks), game.handScores, game.moonShooter, passed, dealt));
    return Replay(hands, game, complete: true);
  }

  static List<List<Card>> _dealt(HeartsGame game) => [for (var s = 0; s < seatCount; s++) game.handOf(s)];
}

class ReplayedHand {
  ReplayedHand(this.index, this.tricks, this.scores, this.moonShooter, this.humanPass, this.dealt);
  final int index;
  final List<List<Play>> tricks;
  final List<int> scores;
  final int? moonShooter;
  final List<Card> humanPass;

  /// Each seat's thirteen as dealt, before the pass: what anybody can
  /// work out from the seed alone (docs/explanation/fair-deal.md).
  final List<List<Card>> dealt;
}

class Replay {
  Replay(this.hands, this.game, {required this.complete});
  final List<ReplayedHand> hands;
  final HeartsGame game;
  final bool complete;
}
