/// A person at a simulated table: plays like a bot after a moment's
/// thought, and leaves — politely, by crashing, by going quiet, or by
/// losing the network — when the scenario says.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'sim_referee.dart';
import 'virtual_clock.dart';

/// When in a game something should happen to a player.
class Moment {
  const Moment(this.name, this.holds, {this.fromHand = 1});

  final String name;
  final bool Function(TableClient c) holds;

  /// Not before this hand, so the departure lands in a game under way.
  final int fromHand;

  static final onOwnTurn = Moment('on own turn', (c) => c.awaitingMyPlay);
  static final offTurn = Moment('off turn', (c) => c.game.phase == Phase.playing && !c.awaitingMyPlay && c.game.trick.isEmpty);
  static final midTrick = Moment('mid-trick', (c) => c.awaitingMyPlay && c.game.trick.isNotEmpty);
  static final lastTrick = Moment('last trick', (c) => c.awaitingMyPlay && c.game.tricksPlayed == 12);
  static final duringPass = Moment('during the pass', (c) => c.awaitingMyPass);
  static final duringDeal = Moment('during the deal', (c) => c.game.phase == Phase.dealing);

  /// The first trick of a hand about to be led: after the deal and the
  /// pass, before a card is played.
  static final handBoundary = Moment('at a hand boundary', (c) => c.game.phase == Phase.playing && c.game.tricksPlayed == 0 && c.game.trick.isEmpty);

  static final all = [onOwnTurn, offTurn, midTrick, lastTrick, duringPass, duringDeal, handBoundary];

  @override
  String toString() => name;
}

/// How a person goes.
enum Going {
  /// Their own leave, from the menu.
  leave,

  /// The app gone: its line closed, never back.
  crash,

  /// There, and doing nothing: the clock has them.
  idle,

  /// The phone off the network: the line down, and back after [ScriptedHuman.backAfterMs].
  offline,
}

class ScriptedHuman {
  ScriptedHuman(this.client, this.line, this.clock, {required this.persona, this.thinkMs = 800, this.backAfterMs});

  final TableClient client;
  final SimLine line;
  final VirtualClock clock;
  final Persona persona;

  /// How long a move takes.
  int thinkMs;

  /// For [Going.offline]: how long until the line is back, or never.
  int? backAfterMs;

  Going? going;
  Moment? goAt;
  bool gone = false;
  int? goneAtHand;

  late final Bot _bot = Bot(persona: persona);
  StreamSubscription<void>? _sub;
  bool _thinking = false;

  void start() {
    client.start();
    _sub = client.changes.listen((_) => _react());
    _react();
  }

  void _react() {
    if (gone || !client.started) return;
    final at = goAt;
    if (at != null && client.game.handNumber >= at.fromHand && at.holds(client)) {
      // Once: a phone back on the network carries on.
      goAt = null;
      _go();
      return;
    }
    if (!client.awaitingMyPass && !client.awaitingMyPlay) return;
    if (_thinking) return;
    _thinking = true;
    clock.schedule(thinkMs, () {
      _thinking = false;
      if (gone) return;
      final seat = client.mySeat!;
      final g = client.game;
      if (client.awaitingMyPass) {
        client.pass(_bot.choosePass(g.handOf(seat)));
      } else if (client.awaitingMyPlay) {
        final view = BotView(
          seat: seat,
          hand: g.handOf(seat),
          trick: g.trick,
          played: client.rules.played,
          heartsBroken: g.heartsBroken,
          isFirstTrick: g.isFirstTrick,
          taken: g.taken,
        );
        client.play(_bot.chooseCard(view, g.legalPlaysFor(seat)));
      }
      _react();
    });
  }

  /// Goes now, by [how], whatever the scenario said.
  void depart(Going how) {
    if (gone) return;
    going = how;
    _go();
  }

  void _go() {
    gone = true;
    goneAtHand = client.started ? client.game.handNumber : 0;
    switch (going!) {
      case Going.leave:
        client.leave();
      case Going.crash:
        line.close();
      case Going.idle:
        break;
      case Going.offline:
        line.hold();
        final back = backAfterMs;
        if (back != null) {
          clock.schedule(back, () {
            line.release();
            gone = false;
          });
        }
    }
  }

  /// Whether this person's client still reads the log: not crashed, and
  /// not off the network for good.
  bool get following => !gone || !(going == Going.crash || (going == Going.offline && line.held && backAfterMs == null));

  void stop() => _sub?.cancel();
}
