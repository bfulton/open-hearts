/// What is done with a picture somebody else chose, and with a player
/// somebody blocked.
///
/// Two different things can keep a picture off the table, and they are
/// not the same kind of thing. The person looking can hide another
/// player's picture on this device, which is their decision and stands
/// until they take it back. And a check on this device can say a
/// picture is one most people would not want at a table, which keeps it
/// off until they ask for it.
///
/// The person looking can also block another player on this device:
/// their picture, their name and their reactions are not shown here,
/// wherever they meet, until they are unblocked. Nobody else is told,
/// and nothing about who sits where changes: seating is worked out in
/// the open by the players' own devices (packages/table, matching.dart),
/// so keeping two players apart would mean saying who blocked whom.
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

  /// Whether it can answer now. A check whose model is still coming
  /// down the wire says false, and holds nothing up while it waits:
  /// pictures show, and are taken back if the answer says so.
  bool get ready => true;
}

class Pictures extends ChangeNotifier {
  Pictures({this.check, Set<String>? hidden, Set<String>? blocked, this.grace = const Duration(seconds: 3)})
      : _hidden = {...?hidden},
        _blocked = {...?blocked};

  static const _hiddenKey = 'pictures_hidden';
  static const _blockedKey = 'players_blocked';

  /// Whatever this device can ask about a picture; null until there is
  /// a model, which is the same as a check that never flags anything.
  final PictureCheck? check;

  /// How long a picture waits on an answer before it is shown anyway.
  final Duration grace;

  /// Keys whose pictures this device does not show, by the viewer's
  /// own decision; kept with the identity.
  final Set<String> _hidden;

  /// Accounts (or keys, where no account names one) the viewer
  /// blocked; kept with the identity.
  final Set<String> _blocked;

  /// Keys whose picture the viewer asked for after the check kept it
  /// off. Not kept: it is about one picture, not a person.
  final Set<String> _asked = {};

  /// What the check said, by the bytes it said it about, so a picture
  /// is read once however many badges it lands on.
  final Map<int, bool> _verdicts = {};
  final Set<int> _running = {};

  /// Bytes that have been drawn once already. They are never held for
  /// an answer after that — a picture that blinks out and back while
  /// the check thinks about it is worse than one that is taken back
  /// when it turns out it should be.
  final Set<int> _drawn = {};

  /// The device's list, as it was left.
  static Future<Pictures> load({PictureCheck? check}) async {
    final prefs = await SharedPreferences.getInstance();
    return Pictures(
      check: check,
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
  /// has not run on these bytes yet.
  ///
  /// A picture waits only where waiting is free: a check with its model
  /// loaded answers in a few milliseconds, and the picture appears once
  /// and correctly. Every other case shows the picture and takes it
  /// back if the answer says so — a model still arriving, an answer
  /// that is taking its time, or bytes already on the table. Being seen
  /// for a moment and withdrawn is the price of failing open, and it is
  /// cheaper than a table of blank badges whenever the check is slow.
  bool allows(String key, Uint8List picture) {
    if (_hidden.contains(key) || _blocked.contains(key)) return false;
    if (_asked.contains(key)) return true;
    final check = this.check;
    if (check == null) return true;
    final digest = _digest(picture);
    final verdict = _verdicts[digest];
    if (verdict != null) return !verdict;
    _start(check, digest, picture);
    if (check.ready && !_drawn.contains(digest)) return false;
    _drawn.add(digest);
    return true;
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
    await prefs.setStringList(_blockedKey, _blocked.toList());
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
