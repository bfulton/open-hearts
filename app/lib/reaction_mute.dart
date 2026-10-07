/// Whether this device shows other players' reactions (packages/table,
/// reactions.dart; ui/reactions.dart): a setting of the device's own,
/// kept beside its other preferences, for anyone at a table or watching
/// one. Muted, nobody else's bubble is drawn or said aloud here; this
/// player's own still shows, and they can still send their own.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReactionMute extends ValueNotifier<bool> {
  ReactionMute() : super(false);

  /// This device's.
  static final current = ReactionMute();

  static const _key = 'reactions_muted';

  /// What the device has kept, read again.
  Future<void> load() async {
    try {
      value = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (_) {
      // Nothing kept, or nowhere to keep it: shown.
    }
  }

  /// Muted or not, from now on, and kept.
  Future<void> set(bool muted) async {
    value = muted;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, muted);
    } catch (_) {
      // Kept for this session, at least.
    }
  }
}
