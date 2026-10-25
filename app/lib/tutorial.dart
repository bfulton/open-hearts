/// Learning to play: a first hand of Hearts with a note at each thing
/// the hand brings a new player to for the first time — the pass, the 2
/// of clubs, following suit, a trick taken, a suit they have none of,
/// hearts broken, the queen, and the score.
///
/// The hand is a game alone like any other, against three bots, dealt
/// the same way every time ([Tutorial.seed]): a deal that comes to every
/// note whatever the player chooses (test/tutorial_test.dart plays it
/// every way the bots and chance can). What to pass and what to play
/// stay the player's. The notes say what the rules allow and what
/// follows from them, never which card to choose (ROADMAP.md, decided
/// against: hints).
///
/// A note is one of two kinds. One that asks for something — three
/// cards to pass, the 2 of clubs, a card of the suit led — stays up
/// until the player has done it; the table is waiting on them anyway.
/// One that tells them something holds the table until they have read
/// it and tapped Next ([Lesson.holds]): the bots wait
/// (game_controller.dart, hold), and the player's own cards wait too
/// (table_page.dart), so nothing moves on under it.
///
/// A hand, never a game: nobody reaches the score a game ends at in
/// one, so nothing is kept (record_store.dart).
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_controller.dart';
import 'l10n/l10n.dart';
import 'record_store.dart';

/// The notes, in the order they are given when two are due at once.
enum Lesson {
  welcome(holds: true),
  pass(holds: false),
  received(holds: true),
  youLead(holds: false),
  theyLead(holds: true),
  follow(holds: false),
  noSuit(holds: false),
  trickTaken(holds: true),
  heartsBroken(holds: true),
  queen(holds: true),
  score(holds: false);

  const Lesson({required this.holds});

  /// Whether the table waits for Next.
  final bool holds;
}

class Tutorial extends ChangeNotifier {
  Tutorial(this.table) {
    table.addListener(_look);
    _look();
  }

  /// The deal every first hand is (game_controller.dart, seed). The 2 of
  /// clubs comes to the player in the pass, so the first card is theirs
  /// to play; by the third trick they hold none of a suit that is led;
  /// and nobody shoots the moon — whatever they pass and play, as
  /// test/tutorial_test.dart holds it to. Chosen from the first 3000 by
  /// that, and by the queen falling in the middle of the hand.
  static const seed = 1102;

  final GameController table;

  final Set<Lesson> _given = {};
  Lesson? _showing;
  Completer<void>? _waiting;

  /// The note up now, if any.
  Lesson? get showing => _showing;

  /// Whether the table waits on the note up now.
  bool get holds => _showing?.holds ?? false;

  /// What the table's pump waits on before it moves on without the
  /// player: done at once unless a note that holds is up.
  Future<void> ready() => holds ? (_waiting ??= Completer<void>()).future : Future.value();

  /// The suit led to the trick on the table, for the notes that name it.
  Suit? get led => table.game.trick.isEmpty ? null : table.game.trick.first.card.suit;

  /// What the note up now says, in [words].
  String? say(AppLocalizations words) => switch (_showing) {
        null => null,
        Lesson.welcome => words.tutorialWelcome,
        Lesson.pass => words.tutorialPass,
        Lesson.received => words.tutorialReceived,
        Lesson.youLead => words.tutorialYouLead,
        Lesson.theyLead => words.tutorialTheyLead(table.names[table.game.currentSeat ?? table.mySeat]),
        Lesson.follow => words.tutorialFollow,
        Lesson.noSuit => table.game.isFirstTrick ? words.tutorialNoSuitFirst : words.tutorialNoSuit(led!.name),
        Lesson.trickTaken => words.tutorialTrickTaken,
        Lesson.heartsBroken => words.tutorialHeartsBroken,
        Lesson.queen => words.tutorialQueen,
        Lesson.score => words.tutorialScore,
      };

  /// Next, tapped: the note that held is read.
  void next() {
    final note = _showing;
    if (note == null || !note.holds) return;
    _given.add(note);
    _showing = null;
    _look();
  }

  @override
  void dispose() {
    table.removeListener(_look);
    _release();
    super.dispose();
  }

  void _look() {
    final note = _showing;
    // A note that asked for something goes once it is done.
    if (note != null && !note.holds && !_due(note)) {
      _given.add(note);
      _showing = null;
    }
    _showing ??= Lesson.values.where((l) => !_given.contains(l) && _due(l)).firstOrNull;
    if (!holds) _release();
    notifyListeners();
  }

  void _release() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  /// Whether [lesson]'s moment is now.
  bool _due(Lesson lesson) {
    final game = table.game;
    final trick = game.trick;
    final mine = game.handOf(table.mySeat);
    final playing = game.phase == Phase.playing;
    // The trick holds its cards until it is swept, the one waiting to
    // be swept included (engine, collectTrick).
    final opening = playing && game.isFirstTrick && trick.isEmpty;
    return switch (lesson) {
      Lesson.welcome || Lesson.pass => table.awaitingPass,
      Lesson.received => opening,
      Lesson.youLead => opening && table.awaitingPlay,
      Lesson.theyLead => opening && !table.awaitingPlay,
      Lesson.follow => table.awaitingPlay && trick.isNotEmpty && mine.any((c) => c.suit == led),
      Lesson.noSuit => table.awaitingPlay && trick.isNotEmpty && !mine.any((c) => c.suit == led),
      Lesson.trickTaken => playing && game.pendingTrick != null,
      Lesson.heartsBroken => playing && game.heartsBroken,
      Lesson.queen => playing && trick.any((p) => p.card == queenOfSpades),
      Lesson.score => game.phase == Phase.handOver,
    };
  }
}

/// Whether this device has been offered the tutorial and taken it up,
/// kept so that the front door stops offering it (home_page.dart).
abstract final class Learning {
  static const _opened = 'tutorial_opened';

  /// Whether the front door offers it: to a device that has not opened
  /// it, and has not finished a game alone either — one that has knows
  /// the way round the table already. It stays in the menu for anyone.
  static Future<bool> offered() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_opened) ?? false) && (prefs.getStringList(PrefsRecordStore.key) ?? const []).isEmpty;
  }

  static Future<void> opened() async => (await SharedPreferences.getInstance()).setBool(_opened, true);
}
