/// Asking for a review: the store's own prompt, on the phones, after a
/// game the player won (ui/overlays.dart, GameOverSheet).
///
/// The prompt is the App Store's or Google Play's, not the app's: the
/// app asks the store to put it up, and the store decides whether it
/// does. Neither says which it did, nor what the player chose; and each
/// keeps its own limit, the App Store three times a year. The app asks
/// once in [reviewGap] at most on top of that, so a player who wins
/// often is asked no more often for it. It asks nothing first of its
/// own ("Do you like the app?"): Google's guidelines rule that out, and
/// Apple's allow no review prompt but the App Store's. What it keeps is
/// the time it last asked, on the device.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'store_review_io.dart' if (dart.library.js_interop) 'store_review_web.dart' as platform;

/// The least time between two asks.
const reviewGap = Duration(days: 120);

/// How long after a won game's sheet comes in the store is asked: the
/// confetti fallen (ui/confetti.dart, confettiFalls), and a moment to
/// read the sheet.
const reviewAfter = Duration(seconds: 4);

/// A store to ask.
abstract class StoreReview {
  /// The one this app asks: the phone's store, or none on the web. A
  /// global, as StoreAge.current is, and settable, so a test can stand
  /// its own store behind it.
  static StoreReview? current = platform.storeReviewHere();

  /// Asks the store for its prompt. The store may put up nothing.
  Future<void> request();
}

/// Where on the device the time of the last ask is kept.
const reviewAskedKey = 'review_asked_at';

/// After a game the player won: asks the store for its prompt, where
/// there is a store and it has not been asked in [reviewGap]. The time
/// is kept before the store is asked, so a store that could not put it
/// up is not asked again at the next win.
Future<void> askForReviewAfterWin({DateTime? now}) async {
  final store = StoreReview.current;
  if (store == null) return;
  final at = now ?? DateTime.now();
  final prefs = await SharedPreferences.getInstance();
  final last = prefs.getInt(reviewAskedKey);
  if (last != null && at.difference(DateTime.fromMillisecondsSinceEpoch(last)) < reviewGap) return;
  await prefs.setInt(reviewAskedKey, at.millisecondsSinceEpoch);
  await store.request();
}
