/// The wait after leaving a live game early (docs/explanation/live-play.md,
/// "Leaving"): when this device last left a game Play live seated it
/// at, with other people still playing, kept on the device and nowhere
/// else. Play live waits the remote config's `leftEarlyMin` from then
/// before it seats this device again (lobby.dart); playing alone and
/// with friends never wait.
///
/// Nothing anywhere else keeps it, so nothing anywhere else holds a
/// device to it: one whose storage was cleared, or a build changed to
/// skip it, plays again at once, as a device that misstates its pace
/// sits with people at a speed it does not play (pace_store.dart). The
/// time is let go once the wait after it is over.
library;

import 'package:shared_preferences/shared_preferences.dart';

abstract final class LeftEarly {
  static const _key = 'live.leftEarlyAt';

  /// The time now, in milliseconds. Settable, so a test can stand its
  /// own clock here.
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// When this device last left a game early, in milliseconds; null for
  /// not lately.
  static Future<int?> load() async => (await SharedPreferences.getInstance()).getInt(_key);

  /// This device left a game early at [atMs]. Of two, the later is kept.
  static Future<void> mark(int atMs) async {
    final prefs = await SharedPreferences.getInstance();
    final was = prefs.getInt(_key);
    if (was != null && was >= atMs) return;
    await prefs.setInt(_key, atMs);
  }

  /// The wait runs from [atMs], whatever was kept: a time kept ahead of
  /// the clock, which was set back since, brought back to now.
  static Future<void> reset(int atMs) async => (await SharedPreferences.getInstance()).setInt(_key, atMs);

  /// The wait is over: nothing kept.
  static Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);

  /// What is left of a [wait] after a game left early at [atMs], at
  /// [nowMs]; null when nothing is. Never more than [wait], whatever the
  /// device's clock did in between.
  static Duration? left({required int? atMs, required int nowMs, required Duration wait}) {
    if (atMs == null || wait <= Duration.zero) return null;
    final since = nowMs - atMs;
    final left = wait.inMilliseconds - (since < 0 ? 0 : since);
    return left > 0 ? Duration(milliseconds: left) : null;
  }
}
