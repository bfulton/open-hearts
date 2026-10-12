/// A person at a simulated table: plays like a bot after a moment's
/// thought, presses Boot when it appears, and leaves — politely, by
/// crashing, or by going quiet — when the scenario says.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'sim_network.dart';
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
  /// The first trick of a hand about to be led: after the deal and the
  /// pass, before a card is played.
  static final handBoundary = Moment('at a hand boundary', (c) => c.game.phase == Phase.playing && c.game.tricksPlayed == 0 && c.game.trick.isEmpty);

  static final all = [onOwnTurn, offTurn, midTrick, lastTrick, duringPass, handBoundary];

  @override
  String toString() => name;
}

enum Exit { leave, crash, idle }

class ScriptedHuman {
  ScriptedHuman(this.client, this.net, this.clock, {required this.persona, this.thinkMs = 800, this.pressBootMs = 500});

  final TableClient client;
  final SimNetwork net;
  final VirtualClock clock;
  final Persona persona;
  /// How long a move takes; a test makes one person slower than the
  /// rest to put a departure after the others have acted.
  int thinkMs;
  final int pressBootMs;

  Exit? exit;
  Moment? exitAt;
  bool gone = false;
  int? leftAtHand;

  late final Bot _bot = Bot(persona: persona);
  StreamSubscription<void>? _sub;
  bool _thinking = false;
  final Set<int> _pressed = {};

  void start() {
    client.start();
    _sub = client.changes.listen((_) => _react());
    _react();
  }

  void _react() {
    if (gone) return;
    final at = exitAt;
    if (at != null && client.game.handNumber >= at.fromHand && at.holds(client)) {
      _go();
      return;
    }
    if (client.awaitingMyPass || client.awaitingMyPlay) {
      if (_thinking) return;
      _thinking = true;
      clock.schedule(thinkMs, () {
        _thinking = false;
        if (gone) return;
        if (client.awaitingMyPass) {
          client.pass(_bot.choosePass(client.game.handOf(client.mySeat!)));
        } else if (client.awaitingMyPlay) {
          final seat = client.mySeat!;
          final view = BotView(
            seat: seat,
            hand: client.game.handOf(seat),
            trick: client.game.trick,
            played: client.played,
            heartsBroken: client.game.heartsBroken,
            isFirstTrick: client.game.isFirstTrick,
            taken: client.game.taken,
          );
          client.play(_bot.chooseCard(view, client.game.legalPlaysFor(seat)));
        }
        _react();
      });
    }
    for (var seat = 0; seat < seatCount; seat++) {
      if (client.canBoot(seat) && _pressed.add(seat * 1000 + client.step)) {
        clock.schedule(pressBootMs, () {
          if (gone) return;
          if (client.canBoot(seat)) {
            client.boot(seat);
          } else {
            _pressed.remove(seat * 1000 + client.step); // not now; maybe later
          }
        });
      }
    }
  }

  /// Leaves now, by [how], whatever the scenario said.
  void depart(Exit how) {
    if (gone) return;
    exit = how;
    _go();
  }

  void _go() {
    gone = true;
    leftAtHand = client.game.handNumber;
    switch (exit!) {
      case Exit.leave:
        client.leave();
      case Exit.crash:
        net.crash(client.signer.publicKey);
      case Exit.idle:
        net.goOffline(client.signer.publicKey);
    }
  }

  void stop() {
    _sub?.cancel();
  }
}
