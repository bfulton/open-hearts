/// What is done with a picture somebody else chose.
///
/// Two different things can keep one off the table, and they are not
/// the same kind of thing. The person looking can hide another
/// player's picture on this device, which is their decision and stands
/// until they take it back. And a check on this device can say a
/// picture is one most people would not want at a table, which keeps it
/// off until they ask for it.
///
/// The check runs here, on the device looking at the picture, never on
/// the one that sent it. A device its owner controls will sign whatever
/// they tell it to, and there is no root of trust on the web to say
/// otherwise; a device the viewer controls answers to the viewer, who
/// is the only person the answer is for.
///
/// It fails open. No check at hand, a model that will not load, bytes
/// it cannot read, an answer that does not come: the picture shows. A
/// check that is right most of the time is worth having; one that hides
/// faces whenever it is unsure is not, and the viewer can always hide a
/// picture themselves.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A verdict on the bytes of a picture: true to keep it off the table,
/// false to show it, null for no answer — which shows it.
abstract class PictureCheck {
  Future<bool?> flagged(Uint8List jpeg);
}

class Pictures extends ChangeNotifier {
  Pictures({this.check, Set<String>? hidden, this.grace = const Duration(seconds: 3)})
      : _hidden = {...?hidden};

  static const _hiddenKey = 'pictures_hidden';

  /// Whatever this device can ask about a picture; null until there is
  /// a model, which is the same as a check that never flags anything.
  final PictureCheck? check;

  /// How long a picture waits on an answer before it is shown anyway.
  final Duration grace;

  /// Keys whose pictures this device does not show, by the viewer's
  /// own decision; kept with the identity.
  final Set<String> _hidden;

  /// Keys whose picture the viewer asked for after the check kept it
  /// off. Not kept: it is about one picture, not a person.
  final Set<String> _asked = {};

  /// What the check said, by the bytes it said it about, so a picture
  /// is read once however many badges it lands on.
  final Map<int, bool> _verdicts = {};
  final Set<int> _running = {};

  /// The device's list, as it was left.
  static Future<Pictures> load({PictureCheck? check}) async {
    final prefs = await SharedPreferences.getInstance();
    return Pictures(check: check, hidden: (prefs.getStringList(_hiddenKey) ?? const <String>[]).toSet());
  }

  bool isHidden(String key) => _hidden.contains(key);

  /// Whether [key]'s picture is off the table for a reason the viewer
  /// did not choose: the check flagged it and they have not asked.
  bool wasFlagged(String key, Uint8List picture) =>
      !_hidden.contains(key) && !_asked.contains(key) && (_verdicts[_digest(picture)] ?? false);

  Future<void> hide(String key) async {
    _asked.remove(key);
    if (!_hidden.add(key)) return;
    await _save();
    notifyListeners();
  }

  /// Show this person's picture: whether the viewer had hidden it or
  /// the check had.
  Future<void> show(String key) async {
    _asked.add(key);
    if (!_hidden.remove(key)) return notifyListeners();
    await _save();
    notifyListeners();
  }

  /// Whether [picture] may be drawn for [key], starting the check if it
  /// has not run on these bytes yet. False for the moment an answer
  /// takes — at most [grace] — and after that only if it flagged them.
  bool allows(String key, Uint8List picture) {
    if (_hidden.contains(key)) return false;
    if (_asked.contains(key)) return true;
    final check = this.check;
    if (check == null) return true;
    final digest = _digest(picture);
    final verdict = _verdicts[digest];
    if (verdict != null) return !verdict;
    _start(check, digest, picture);
    return false;
  }

  void _start(PictureCheck check, int digest, Uint8List picture) {
    if (!_running.add(digest)) return;
    Future<bool?>(() => check.flagged(picture))
        .timeout(grace, onTimeout: () => null)
        .catchError((Object _) => null)
        .then((flagged) {
      _running.remove(digest);
      // No answer is not a flag: the picture shows.
      _verdicts[digest] = flagged ?? false;
      notifyListeners();
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, _hidden.toList());
  }

  /// FNV-1a over the bytes: a name for a picture, not a promise about
  /// it — two pictures that collide only share a verdict.
  static int _digest(Uint8List bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }
}
