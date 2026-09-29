/// Where finished solo games are kept: on the device, newest first, a
/// line of text each (see SoloRecord in the engine). Nothing leaves the
/// device unless the player copies a record out.
library;

import 'package:shared_preferences/shared_preferences.dart';

abstract class RecordStore {
  Future<List<String>> load();
  Future<void> save(String record);
}

/// Records in the platform's preferences: local storage on the web,
/// the app's own store on a phone.
class PrefsRecordStore implements RecordStore {
  static const key = 'solo_records';

  /// How many games to keep. Records are short, but the point is to
  /// look at a recent hand, not to hoard.
  static const keep = 30;

  @override
  Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key) ?? const [];
  }

  @override
  Future<void> save(String record) async {
    final prefs = await SharedPreferences.getInstance();
    final kept = <String>[record, ...?prefs.getStringList(key)];
    await prefs.setStringList(key, kept.take(keep).toList());
  }
}

/// A store that remembers nothing between runs, for tests.
class MemoryRecordStore implements RecordStore {
  final List<String> records = [];

  @override
  Future<List<String>> load() async => List.of(records);

  @override
  Future<void> save(String record) async => records.insert(0, record);
}
