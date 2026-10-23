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

  /// A card coming down onto its place in the trick, and the player's
  /// own leaving the hand for it (ui/table_view.dart, ui/hand_fan.dart).
  static const cardLands = Duration(milliseconds: 240);

  /// A finished trick swept off to whoever took it (ui/table_view.dart).
  static const trickSweeps = Duration(milliseconds: 300);

  /// A moon's quake, from the moment the last trick reaches whoever
  /// shot it (ui/table_view.dart): over within the beat of bare felt
  /// after a hand, [sweepBeat], so the sheet comes down on a still table.
  static const moonQuake = Duration(milliseconds: 900);

  /// A seat's glow as the cards of a trick with points reach it: pink,
  /// and the queen's red half a second longer (ui/table_view.dart).
  static const pointsGlow = Duration(milliseconds: 900);
  static const queenGlow = Duration(milliseconds: 1400);

  /// How long [persona]'s bot appears to think: a draw from its rhythm.
  static Duration think(Persona persona, Random rhythm) {
    final pace = persona.pace;
    return Duration(milliseconds: pace.minMs + rhythm.nextInt(pace.maxMs - pace.minMs + 1));
  }
}
