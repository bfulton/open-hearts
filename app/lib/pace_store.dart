/// This device's own pace, kept on it (packages/table, pace.dart).
///
/// Not on a relay and not in a result. It is measured by the device
/// that played the cards, kept by it, and stated by it in the pool the
/// way a rating is stated there. It decides who you sit with and nothing
/// else, and nobody is ever told how long you took.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

class PaceStore {
  static const _key = 'pace';

  /// What this device has measured of itself so far.
  static Future<Pace> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return Pace.fresh;
    try {
      return Pace.parse(jsonDecode(raw));
    } catch (_) {
      return Pace.fresh;
    }
  }

  static Future<void> save(Pace pace) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(pace.toJson()));

  /// A game's worth of this device's own cards folded in, and the
  /// pace that leaves. [cardMs] is how long this player took over each
  /// of their own cards, as this device timed them
  /// (`LiveController.myCardMs`).
  static Future<Pace> fold(Iterable<int> cardMs) async {
    // A turn this device was away for is not a think: a phone in a
    // pocket during a hand would otherwise read as somebody very slow
    // for ever. Anything past the bank's own patience is dropped
    // rather than counted, since it was not time spent deciding.
    final counted = [for (final ms in cardMs) if (ms >= 0 && ms <= _longestThink) ms];
    if (counted.isEmpty) return load();
    final pace = (await load()).plus(
      cards: counted.length,
      seconds: counted.fold<int>(0, (a, b) => a + b) / 1000,
    );
    await save(pace);
    return pace;
  }

  /// Past this, a turn was a person who walked away, not a person
  /// thinking: a card's grace plus the whole bank, which is what the
  /// table itself allows before anybody may be booted.
  static final _longestThink = TimeBank.standard.graceMs + TimeBank.standard.bankMs;
}
