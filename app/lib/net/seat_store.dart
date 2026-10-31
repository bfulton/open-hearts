/// The seat this device is playing in, kept on the device so that a
/// page reloaded mid-game comes back to it (live/lobby.dart; packages/
/// table, journal.dart).
///
/// What is kept: the table (its spec, the names and looks it was
/// started with, and whether Play live seated it with strangers), when
/// this device was last at it, and the table's journal — each hand's
/// deal secret, written as the client draws it, before anything made
/// from it goes out: localStorage takes a write at once, so a reload
/// never loses the secret its seat's keys were made from. Everything
/// else the device said is in the table's log, which a device back at
/// the table reads from its start. One table at a time; cleared when
/// the game is over or left, or found too old to come back to.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import '../avatar.dart';

/// A seat kept from before a reload.
class KeptSeat {
  const KeptSeat(
      {required this.spec, required this.names, required this.avatars, required this.at, required this.journal, this.strangers = false});

  final TableSpec spec;
  final Map<int, String> names;
  final Map<int, Avatar> avatars;

  /// Whether Play live seated the table, rather than a friends' room:
  /// leaving its game early is waited out (live/left_early.dart).
  final bool strangers;

  /// When this device was last at the table, in milliseconds.
  final int at;
  final TableJournal journal;
}

class SeatStore {
  SeatStore._(this._prefs);

  static const _table = 'seat.table';
  static const _at = 'seat.at';
  static const _secret = 'seat.secret.';

  /// Longer away than this and the seat is somebody else's by now: a
  /// table removes a seat whose connection has been closed for its
  /// silence at its turn, half a minute (packages/table, rules.dart,
  /// TableTiming.silenceMs). Room left for a slow load, and for a turn
  /// that came round late.
  static const comeBackWithin = Duration(minutes: 2);

  final SharedPreferences _prefs;

  static Future<SeatStore> open() async => SeatStore._(await SharedPreferences.getInstance());

  /// Starts keeping a new table, in place of any kept before; the
  /// journal its client writes to, already writing here. [journal] is
  /// one read back by [load], whose secrets are here already.
  TableJournal keep(TableSpec spec, Map<int, String> names, Map<int, Avatar> avatars, {TableJournal? journal, bool strangers = false}) {
    if (journal == null) clear();
    _prefs.setString(_table, jsonEncode({
      'spec': spec.toJson(),
      'names': {for (final e in names.entries) '${e.key}': e.value},
      'avatars': {for (final e in avatars.entries) '${e.key}': e.value.toJson(withPicture: false)},
      if (strangers) 'strangers': true,
    }));
    here();
    final j = journal ?? TableJournal();
    j.onKept = (hand, secret) => _prefs.setString('$_secret$hand', base64.encode(secret));
    return j;
  }

  /// This device is at the table now.
  void here() => _prefs.setInt(_at, DateTime.now().millisecondsSinceEpoch);

  /// The seat kept, or null for none — or one too long ago to come back
  /// to, which is cleared on the way, and told to [gone] first: this
  /// device was away from a game it never finished for longer than the
  /// table waits (live/left_early.dart). Without its journal, which
  /// nothing will read again.
  KeptSeat? load({DateTime? now, void Function(KeptSeat seat)? gone}) {
    final raw = _prefs.getString(_table);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, Object?>;
      final spec = TableSpec.parse(m['spec']);
      final at = _prefs.getInt(_at) ?? 0;
      final ago = (now ?? DateTime.now()).millisecondsSinceEpoch - at;
      if (spec == null || ago < 0 || ago > comeBackWithin.inMilliseconds) {
        if (spec != null && ago > comeBackWithin.inMilliseconds) {
          gone?.call(KeptSeat(spec: spec, names: const {}, avatars: const {}, at: at, journal: TableJournal(), strangers: m['strangers'] == true));
        }
        clear();
        return null;
      }
      final secrets = <int, Uint8List>{
        for (final k in _prefs.getKeys())
          if (k.startsWith(_secret)) int.parse(k.substring(_secret.length)): base64.decode(_prefs.getString(k)!),
      };
      return KeptSeat(
        spec: spec,
        names: {for (final e in (m['names'] as Map).entries) int.parse(e.key as String): e.value as String},
        avatars: {for (final e in (m['avatars'] as Map).entries) int.parse(e.key as String): Avatar.fromJson(e.value)},
        at: at,
        journal: TableJournal(secrets: secrets),
        strangers: m['strangers'] == true,
      );
    } catch (_) {
      clear();
      return null;
    }
  }

  /// No seat kept: the game over, left, or lost.
  void clear() {
    for (final k in _prefs.getKeys().toList()) {
      if (k.startsWith('seat.')) _prefs.remove(k);
    }
  }
}
