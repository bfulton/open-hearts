/// What is done with a picture somebody else chose, and with a player
/// somebody blocked.
///
/// The person looking can hide another player's picture on this device,
/// which is their decision and stands until they take it back. Whether a
/// picture may be shown at all is the service's to check, once, when the
/// account keeps it (docs/explanation/service.md, the account's profile),
/// and the relay carries only an account's checked picture
/// (docs/explanation/relay.md, an account's pictures).
///
/// The person looking can also block another player on this device:
/// their picture, their name and their reactions are not shown here,
/// wherever they meet, until they are unblocked. Nobody else is told,
/// and nothing about who sits where changes: seating is worked out in
/// the open by the players' own devices (packages/table, matching.dart),
/// so keeping two players apart would mean saying who blocked whom.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Pictures extends ChangeNotifier {
  Pictures({Set<String>? hidden, Set<String>? blocked})
      : _hidden = {...?hidden},
        _blocked = {...?blocked};

  static const _hiddenKey = 'pictures_hidden';
  static const _blockedKey = 'players_blocked';

  /// Keys whose pictures this device does not show, by the viewer's
  /// own decision; kept with the identity.
  final Set<String> _hidden;

  /// Accounts (or keys, where no account names one) the viewer
  /// blocked; kept with the identity.
  final Set<String> _blocked;

  /// The device's list, as it was left.
  static Future<Pictures> load() async {
    final prefs = await SharedPreferences.getInstance();
    return Pictures(
      hidden: (prefs.getStringList(_hiddenKey) ?? const <String>[]).toSet(),
      blocked: (prefs.getStringList(_blockedKey) ?? const <String>[]).toSet(),
    );
  }

  bool isHidden(String key) => _hidden.contains(key);

  /// Whether the viewer blocked [key]: nothing of theirs is shown here.
  bool isBlocked(String key) => _blocked.contains(key);

  Future<void> block(String key) async {
    if (!_blocked.add(key)) return;
    await _save();
    notifyListeners();
  }

  Future<void> unblock(String key) async {
    if (!_blocked.remove(key)) return;
    await _save();
    notifyListeners();
  }

  Future<void> hide(String key) async {
    if (!_hidden.add(key)) return;
    await _save();
    notifyListeners();
  }

  /// Shows this person's picture again, after the viewer hid it.
  Future<void> show(String key) async {
    if (!_hidden.remove(key)) return;
    await _save();
    notifyListeners();
  }

  /// Whether [key]'s picture may be drawn here: not hidden, and not
  /// blocked.
  bool allows(String key) => !_hidden.contains(key) && !_blocked.contains(key);

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, _hidden.toList());
    await prefs.setStringList(_blockedKey, _blocked.toList());
  }
}
