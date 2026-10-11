/// How a table is paced on the screen, at a solo table and a live one
/// alike (game_controller.dart, live/live_controller.dart): what a
/// person watching needs to see each thing happen.
library;

import 'dart:math';

import 'package:engine/engine.dart' show Persona;

/// The share of its beats a table takes — a bot's thinking, a trick
/// held on the felt, the score sheet's stay: all of them, but for a
/// build the browser suites drive and ask for less (net/address.dart,
/// `paceIn`). Set once, at startup (main.dart).
double tableBeats = 1;

abstract final class Pacing {
  /// A finished trick held on the felt before it is swept.
  static const trickHold = Duration(milliseconds: 950);

  /// After the last trick of a hand is swept, a beat of bare felt
  /// before the sheet. Long enough to watch the last trick go to
  /// whoever took it and to take the felt in after: a sheet that comes
  /// down on the tail of the cards leaves the hand's last thing
  /// unseen, and the score it is about unexplained.
  static const sweepBeat = Duration(milliseconds: 1200);

  /// How long [persona]'s bot appears to think: a draw from its rhythm.
  static Duration think(Persona persona, Random rhythm) {
    final pace = persona.pace;
    return Duration(milliseconds: pace.minMs + rhythm.nextInt(pace.maxMs - pace.minMs + 1));
  }
}
