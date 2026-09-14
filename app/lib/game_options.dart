/// The game this device asks for: how far it plays, and whether it
/// counts. Kept on the device beside the name and the avatar
/// (identity.dart), because it is a standing preference rather than
/// something to settle again at every table.
///
/// The target is a rule of the game, so a live table carries it in the
/// signed start event and every seat plays to the same number
/// (`TableSpec.target`); rated is the pool the player waits in.
library;

import 'package:engine/engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GameOptions {
  const GameOptions({this.target = gameOverScore, this.rated = true});

  /// The two lengths offered: a few hands, or an evening of it.
  static const targets = [gameOverScore, longGameScore];

  /// The score the game runs to.
  final int target;

  /// Whether the result moves the players' ratings.
  final bool rated;

  /// The choice on one line: "50 points · rated".
  String get line => '$target points · ${rated ? 'rated' : 'unrated'}';

  /// The pool this asks for on the relay (packages/table, matching.dart).
  String get pool => rated ? 'rated' : 'unrated';

  GameOptions copyWith({int? target, bool? rated}) =>
      GameOptions(target: target ?? this.target, rated: rated ?? this.rated);

  static const _targetKey = 'game_target';
  static const _ratedKey = 'game_rated';

  static Future<GameOptions> load() async {
    final prefs = await SharedPreferences.getInstance();
    return GameOptions(target: prefs.getInt(_targetKey) ?? gameOverScore, rated: prefs.getBool(_ratedKey) ?? true);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_targetKey, target);
    await prefs.setBool(_ratedKey, rated);
  }

  @override
  bool operator ==(Object other) => other is GameOptions && other.target == target && other.rated == rated;

  @override
  int get hashCode => Object.hash(target, rated);
}
