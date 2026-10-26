/// The tutorial's hand (tutorial.dart), on a fake clock: every note
/// comes, once, whatever the player passes and plays; a note that tells
/// holds the bots until Next; one that asks goes once it is done.
library;

import 'dart:math';

import 'package:engine/engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/game_controller.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/record_store.dart';
import 'package:open_hearts/tutorial.dart';

/// A player at the tutorial's table: what they pass, and what they play.
typedef Strategy = ({String name, List<Card> Function(List<Card> hand, Random r) pass, Card Function(BotView view, List<Card> legal, Random r) play});

/// Every player the hand is held to: each bot's own pass and play, and
/// players choosing at random, highest first or lowest first.
List<Strategy> get players {
  int value(Card c) => c.rank.value + (c.suit == Suit.hearts ? 20 : 0) + (c == queenOfSpades ? 40 : 0);
  List<Card> sorted(List<Card> cards) => List.of(cards)..sort((a, b) => value(a).compareTo(value(b)));
  return [
    for (final p in Persona.roster)
      (name: p.name, pass: (h, _) => Bot(persona: p).choosePass(h), play: (v, l, _) => Bot(persona: p).chooseCard(v, l)),
    (name: 'highest', pass: (h, _) => sorted(h).reversed.take(passSize).toList(), play: (_, l, _) => sorted(l).last),
    (name: 'lowest', pass: (h, _) => sorted(h).take(passSize).toList(), play: (_, l, _) => sorted(l).first),
    for (var i = 0; i < 8; i++)
      (name: 'at random $i', pass: (h, r) => (List.of(h)..shuffle(r)).take(passSize).toList(), play: (_, l, r) => l[r.nextInt(l.length)]),
  ];
}

/// What a table shows that a note being read holds still: whose cards
/// are where, the trick and the one being swept, and the pass.
String still(GameController table) {
  final g = table.game;
  return '${g.phase} ${g.tricksPlayed} ${g.trick.map((p) => p.card)} ${g.pendingTrick?.plays.map((p) => p.card)} '
      '${[for (var s = 0; s < seatCount; s++) '${g.handOf(s).length}/${g.passOf(s)?.length}']}';
}

/// The tutorial's hand played by [player], Next tapped on every note that
/// holds once a minute has gone by with nothing moving under it, and
/// the rest of the hand left to Auto as soon as it is offered where
/// [auto]: the notes in the order they came, and the controller after.
/// [seed] is the player's own chance, where they choose at random; and
/// [deal] another deal than the tutorial's, to hold the notes to.
({List<Lesson> notes, GameController table}) playThrough(Strategy player, {required int seed, bool auto = false, int deal = Tutorial.seed}) {
  late GameController table;
  late Tutorial tutorial;
  final notes = <Lesson>[];
  fakeAsync((async) {
    final random = Random(seed);
    table = GameController(seed: deal, paced: false, store: MemoryRecordStore(), hold: () => tutorial.ready());
    tutorial = Tutorial(table)
      ..addListener(() {
        final showing = tutorial.showing;
        if (showing != null && (notes.isEmpty || notes.last != showing)) notes.add(showing);
      });
    final first = tutorial.showing;
    if (first != null) notes.add(first);
    for (var i = 0; i < 2000 && table.game.phase != Phase.handOver; i++) {
      if (auto && table.autoOffered && !table.autoPlay) table.setAutoPlay(true);
      if (tutorial.holds) {
        // Nothing moves under a note being read, however long it is up:
        // no card played, by a bot or for the player, no trick swept.
        final before = still(table);
        async.elapse(const Duration(minutes: 1));
        expect(still(table), before, reason: '${player.name}: the table moved under ${tutorial.showing}');
        tutorial.next();
      } else if (table.awaitingPass) {
        for (final card in player.pass(table.game.handOf(table.mySeat), random)) {
          table.toggleSelected(card);
        }
        table.confirmPass();
      } else if (table.awaitingPlay) {
        final game = table.game;
        // The note is the one for the hand held: following suit where it
        // can be, and a suit it has none of where it cannot.
        final suited = game.trick.isNotEmpty && game.handOf(table.mySeat).any((c) => c.suit == tutorial.led);
        if (tutorial.showing == Lesson.follow) expect(suited, isTrue, reason: '${player.name}: told to follow, with none of the suit');
        if (tutorial.showing == Lesson.noSuit) expect(suited, isFalse, reason: '${player.name}: told it has none, with the suit in hand');
        final view = BotView(
            seat: table.mySeat,
            hand: game.handOf(table.mySeat),
            trick: game.trick,
            played: table.playedThisHand,
            heartsBroken: game.heartsBroken,
            isFirstTrick: game.isFirstTrick,
            taken: game.taken);
        expect(table.playCard(player.play(view, table.legalNow.toList(), random)), isNull);
      }
      async.elapse(const Duration(milliseconds: 10));
    }
    async.elapse(const Duration(seconds: 1));
  });
  return (notes: notes, table: table);
}

/// The table and its notes, on a fake clock the caller drives.
({GameController table, Tutorial tutorial}) teach({int seed = Tutorial.seed}) {
  late Tutorial tutorial;
  final table = GameController(seed: seed, paced: false, store: MemoryRecordStore(), hold: () => tutorial.ready());
  tutorial = Tutorial(table);
  return (table: table, tutorial: tutorial);
}

void passAny(GameController table) {
  for (final card in table.game.handOf(table.mySeat).take(passSize)) {
    table.toggleSelected(card);
  }
  table.confirmPass();
}

void main() {
  test('the hand comes to every note, once each, whatever the player passes and plays; nothing moves under one being read', () {
    for (final (i, player) in players.indexed) {
      // Every other player leaves the rest of the hand to Auto once it
      // is offered, and the notes come all the same.
      final (:notes, :table) = playThrough(player, seed: 1000 + i, auto: i.isOdd);
      expect(table.game.phase, Phase.handOver, reason: '${player.name}: the hand played out');
      expect(notes.toSet().length, notes.length, reason: '${player.name}: no note twice, $notes');
      expect(notes.toSet(), Lesson.values.toSet().difference({Lesson.theyLead}),
          reason: '${player.name}: every note but the one for a bot holding the 2 of clubs, which comes to the player in the pass');
      expect(notes.take(4), [Lesson.welcome, Lesson.pass, Lesson.received, Lesson.youLead], reason: player.name);
      expect(notes.last, Lesson.score, reason: player.name);
      expect(table.game.moonShooter, isNull, reason: '${player.name}: nobody shoots the moon');
    }
  });

  test('on other deals too, a note is the one for the hand held, and nothing moves under one being read', () {
    // The tutorial's deal comes to a suit the player has none of at the
    // first trick they follow after the one they follow suit in; other
    // deals come to it later, or never, and hold the notes to the hand
    // all the same.
    final lowest = players.firstWhere((p) => p.name == 'lowest');
    for (var deal = 1; deal <= 40; deal++) {
      final (:notes, :table) = playThrough(lowest, seed: deal, deal: deal);
      expect(table.game.phase, Phase.handOver, reason: 'deal $deal: the hand played out');
      expect(notes.toSet().length, notes.length, reason: 'deal $deal: no note twice, $notes');
    }
  });

  test('a note that tells holds the bots, however long it is up, until Next', () {
    fakeAsync((async) {
      final (:table, :tutorial) = teach();
      expect(tutorial.showing, Lesson.welcome);
      expect(tutorial.holds, isTrue);
      tutorial.next();
      expect(tutorial.showing, Lesson.pass);
      passAny(table);
      async.elapse(const Duration(minutes: 1));
      // The pass made; the cards that came are told of first, and the
      // table waits on that: nobody has led.
      expect(tutorial.showing, Lesson.received);
      expect(table.game.phase, Phase.playing);
      expect(table.game.trick, isEmpty);
      tutorial.next();
      async.elapse(const Duration(seconds: 1));
      expect(tutorial.showing, Lesson.youLead, reason: 'the 2 of clubs came in the pass');
      expect(table.playCard(twoOfClubs), isNull);
      async.elapse(const Duration(seconds: 1));
      // Three bots follow, and the trick sits on the table, all four
      // cards, until the note on it is read.
      expect(tutorial.showing, Lesson.trickTaken);
      async.elapse(const Duration(minutes: 1));
      expect(table.game.pendingTrick, isNotNull, reason: 'not swept while the note is up');
      expect(table.game.tricksPlayed, 0);
      tutorial.next();
      async.elapse(const Duration(seconds: 1));
      expect(table.game.tricksPlayed, 1, reason: 'swept once it is read');
      table.dispose();
      tutorial.dispose();
    });
  });

  test('a note that asks goes once what it asks is done, and holds nothing meanwhile', () {
    fakeAsync((async) {
      final (:table, :tutorial) = teach();
      tutorial.next();
      expect(tutorial.showing, Lesson.pass);
      expect(tutorial.holds, isFalse);
      var ready = false;
      tutorial.ready().then((_) => ready = true);
      async.flushMicrotasks();
      expect(ready, isTrue, reason: 'a note that asks holds nothing');
      tutorial.next();
      expect(tutorial.showing, Lesson.pass, reason: 'Next is no answer to a note that asks');
      passAny(table);
      expect(tutorial.showing, isNot(Lesson.pass), reason: 'the pass made, its note goes');
      table.dispose();
      tutorial.dispose();
    });
  });

  test('a note that holds the table holds the card Auto would play for the player too', () {
    // Another deal than the tutorial's, where the hand is left to Auto
    // before the queen of spades falls, and she falls with the player
    // to play next: one deal in the first four hundred.
    fakeAsync((async) {
      final (:table, :tutorial) = teach(seed: 354);
      bool there() => tutorial.showing == Lesson.queen && table.autoPlay && table.game.currentSeat == table.mySeat;
      for (var i = 0; i < 2000 && !there(); i++) {
        if (table.autoOffered && !table.autoPlay) table.setAutoPlay(true);
        if (tutorial.holds) {
          tutorial.next();
        } else if (table.awaitingPass) {
          passAny(table);
        } else if (table.awaitingPlay && !table.autoPlay) {
          table.playCard(table.legalNow.first);
        }
        async.elapse(const Duration(milliseconds: 10));
      }
      expect(there(), isTrue, reason: 'the queen\'s note up, Auto on, and the player to play');
      final before = still(table);
      async.elapse(const Duration(minutes: 1));
      expect(still(table), before, reason: 'Auto waits on the note, as the bots do');
      tutorial.next();
      async.elapse(const Duration(seconds: 1));
      expect(still(table), isNot(before), reason: 'and plays once it is read');
      table.dispose();
      tutorial.dispose();
    });
  });

  test('a table left while a note holds it is let go, and nothing on it moves after', () {
    fakeAsync((async) {
      final (:table, :tutorial) = teach();
      // To the first trick, all four cards down, which the note on it
      // holds on the table.
      for (var i = 0; i < 200 && tutorial.showing != Lesson.trickTaken; i++) {
        if (tutorial.holds) {
          tutorial.next();
        } else if (table.awaitingPass) {
          passAny(table);
        } else if (table.awaitingPlay) {
          table.playCard(table.legalNow.first);
        }
        async.elapse(const Duration(milliseconds: 10));
      }
      expect(tutorial.showing, Lesson.trickTaken);
      var released = false;
      tutorial.ready().then((_) => released = true);
      async.elapse(const Duration(seconds: 5));
      expect(released, isFalse);
      final before = still(table);
      // The page goes, the note with it: what waited on the note is let
      // go rather than left waiting for good (table_page.dart, dispose),
      // and the table it was waiting to move is gone, so does not move.
      tutorial.dispose();
      table.dispose();
      async.elapse(const Duration(seconds: 5));
      expect(released, isTrue);
      expect(still(table), before);
    });
  });

  test('where a bot holds the 2 of clubs, the note names it and holds the lead until Next', () {
    // Another deal than the tutorial's, where the 2 of clubs stays
    // with a bot.
    fakeAsync((async) {
      for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
        final (:table, :tutorial) = teach(seed: seed);
        tutorial.next();
        passAny(table);
        async.elapse(const Duration(seconds: 1));
        tutorial.next();
        async.elapse(const Duration(seconds: 1));
        if (tutorial.showing != Lesson.theyLead) {
          table.dispose();
          tutorial.dispose();
          continue;
        }
        final leader = table.game.currentSeat!;
        expect(leader, isNot(table.mySeat));
        expect(tutorial.say(english), 'The 2 of clubs leads the first trick, and ${table.names[leader]} has it.');
        async.elapse(const Duration(minutes: 1));
        expect(table.game.trick, isEmpty, reason: 'the bot waits on the note');
        tutorial.next();
        async.elapse(const Duration(seconds: 5));
        expect(table.game.trick.first.card, twoOfClubs, reason: 'and leads once it is read');
        table.dispose();
        tutorial.dispose();
        return;
      }
      fail('no deal among these where a bot keeps the 2 of clubs');
    });
  });

  test('the note for a suit you have none of names it, and on the first trick says no points', () {
    fakeAsync((async) {
      // The tutorial's own deal: spades, by the third trick.
      final (:table, :tutorial) = teach();
      for (var i = 0; i < 2000 && (tutorial.showing != Lesson.noSuit && table.game.phase == Phase.playing || table.awaitingPass); i++) {
        if (tutorial.holds) {
          tutorial.next();
        } else if (table.awaitingPass) {
          passAny(table);
        } else if (table.awaitingPlay) {
          table.playCard(table.legalNow.first);
        }
        async.elapse(const Duration(milliseconds: 10));
      }
      final led = table.game.trick.first.card.suit;
      expect(table.game.handOf(table.mySeat).where((c) => c.suit == led), isEmpty);
      expect(tutorial.say(english), startsWith('You have no ${led.name}, so any card will do.'));
      for (final locale in AppLocalizations.supportedLocales) {
        final words = lookupAppLocalizations(locale);
        expect(tutorial.say(words), words.tutorialNoSuit(led.name), reason: locale.languageCode);
      }
      table.dispose();
      tutorial.dispose();

      // A deal where the player has no clubs to follow the 2 with: the
      // first trick, where no points may go.
      for (var seed = 1; seed < 400; seed++) {
        final (:table, :tutorial) = teach(seed: seed);
        for (var i = 0; i < 200 && !table.awaitingPlay; i++) {
          if (tutorial.holds) {
            tutorial.next();
          } else if (table.awaitingPass) {
            passAny(table);
          }
          async.elapse(const Duration(milliseconds: 10));
        }
        final first = table.game.isFirstTrick && table.game.trick.isNotEmpty;
        if (first && tutorial.showing == Lesson.noSuit) {
          expect(tutorial.say(english), english.tutorialNoSuitFirst);
          table.dispose();
          tutorial.dispose();
          return;
        }
        table.dispose();
        tutorial.dispose();
      }
      fail('no deal among these leaves the player without clubs on the first trick');
    });
  });
}
