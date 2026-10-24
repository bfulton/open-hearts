/// What a phone's store says of the player's age, asked as they go to a
/// live table and before they buy live play in the store.
///
/// The terms let anyone play alone and anyone 13 or older play live
/// (site/strings, terms.age). Where a law has the stores keep everyone's
/// age (Texas's App Store Accountability Act among them), the store
/// tells an app the person's age range and whether a parent or guardian
/// has approved, and the app is to go by it. The App Store says it
/// through Apple's Declared Age Range, and Google Play through its Age
/// Signals; this asks both through the age_range_signals plugin
/// (age_check_io.dart).
///
/// What comes back decides one thing, whether live play opens, and is
/// kept nowhere: not on the device, not in memory once it has decided,
/// and never sent. Where the store has nothing to say (the web, a phone
/// the store keeps no age for, a player who chose not to share it, a
/// store that did not answer) the terms decide, as they always have.
library;

import 'age_check_io.dart' if (dart.library.js_interop) 'age_check_web.dart' as platform;

/// The one age the terms draw a line at in the app: live play's.
const livePlayFrom = 13;

/// What live play makes of what the store said.
enum AgeVerdict {
  /// Nothing the store said closes live play.
  open,

  /// The store says the player is under [livePlayFrom].
  tooYoung,

  /// Google Play: a parent or guardian is yet to approve the app's
  /// latest significant change.
  awaitingParent,

  /// Google Play: a parent or guardian declined it.
  parentDeclined,

  /// Google Play: the player is to confirm their age in the Play Store
  /// first, which it asks only where a law has it keep everyone's age.
  unconfirmed,
}

/// A store to ask.
abstract class StoreAge {
  /// The one this app asks: the phone's store, or none on the web. A
  /// global, as StoreShop.current is, and settable, so a test can stand
  /// its own store behind it.
  static StoreAge? current = platform.storeAgeHere();

  /// What the store says, as a verdict on live play: [AgeVerdict.open]
  /// whenever it has nothing to say.
  Future<AgeVerdict> ask();
}

/// What the store here says of live play for this player, or open
/// where there is no store to ask.
Future<AgeVerdict> askStoreAge() async => await StoreAge.current?.ask() ?? AgeVerdict.open;
