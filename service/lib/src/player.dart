/// A person at a table over real sockets, played by the bot: the
/// suites' stand-in for a human, and the measurement tools' too.
///
/// Here so that anything in this package can seat one — a test, or a
/// tool measuring what a hand costs on the wire.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:table/table.dart';

class Player {
  Player(this.client, {this.thinkMs = 30}) : bot = Bot() {
    _sub = client.changes.listen((_) => _react());
    _react();
  }

  final TableClient client;
  final Bot bot;

  /// How long each decision takes. Thirty milliseconds plays a game in
  /// seconds; a test that needs the game to outlast something slower
  /// asks for more.
  final int thinkMs;
  StreamSubscription<void>? _sub;
  bool _thinking = false;
  bool _stopped = false;

  void _react() {
    if (_stopped || _thinking || !(client.awaitingMyPass || client.awaitingMyPlay)) return;
    _thinking = true;
    Future<void>.delayed(Duration(milliseconds: thinkMs), () {
      _thinking = false;
      // A thought begun before the player was stopped is not played
      // after it: the test that stopped it has taken its log, and its
      // client, away.
      if (_stopped) return;
      final seat = client.mySeat!;
      if (client.awaitingMyPass) {
        client.pass(bot.choosePass(client.game.handOf(seat)));
      } else if (client.awaitingMyPlay) {
        final view = BotView(
          seat: seat,
          hand: client.game.handOf(seat),
          trick: client.game.trick,
          played: client.rules.played,
          heartsBroken: client.game.heartsBroken,
          isFirstTrick: client.game.isFirstTrick,
          taken: client.game.taken,
        );
        client.play(bot.chooseCard(view, client.game.legalPlaysFor(seat)));
      }
      _react();
    });
  }

  void stop() {
    _stopped = true;
    _sub?.cancel();
  }
}
