/// The App Store's Declared Age Range and Google Play's Age Signals,
/// through the age_range_signals plugin.
///
/// Asked for the one line the app draws, [livePlayFrom]: Apple then
/// shares no more than whether the player is under it or not. Google
/// Play answers in its own bands whatever is asked, and is gone by
/// only as far as that line. Its approval statuses are for a
/// supervised player, whose parent or guardian approves the app's
/// significant changes in Google Play; Apple has no such answer, and
/// stops the app opening at all where a parent's approval is withdrawn.
library;

import 'dart:io' show Platform;

import 'package:age_range_signals/age_range_signals.dart';
import 'package:flutter/foundation.dart';

import 'age_check.dart';

StoreAge? storeAgeHere() => Platform.isIOS || Platform.isAndroid ? PhoneAge() : null;

/// The phone's own store, asked through the plugin.
class PhoneAge implements StoreAge {
  bool _gated = false;

  /// The question being asked, which a second one waits on rather than
  /// putting the store's sheet up twice.
  Future<AgeVerdict>? _asking;

  @override
  Future<AgeVerdict> ask() => _asking ??= _ask().whenComplete(() => _asking = null);

  Future<AgeVerdict> _ask() async {
    final signals = AgeRangeSignals.instance;
    try {
      if (!_gated) {
        await signals.initialize(ageGates: const [livePlayFrom]);
        _gated = true;
      }
      // Google Play can put up its sheet asking to share here; the App
      // Store says yes and asks in the next step.
      final access = await signals.requestAgeSignalsAccess();
      if (access == AgeSignalsAccessStatus.verificationRequired) return AgeVerdict.unconfirmed;
      if (access != AgeSignalsAccessStatus.shared) return AgeVerdict.open;
      return verdictOf(await signals.checkAgeSignals());
    } on Exception catch (e) {
      // Nothing to go on: an iPhone before iOS 26, a phone without Google
      // Play's services, a store that did not answer.
      debugPrint('age: the store did not say: $e');
      return AgeVerdict.open;
    }
  }
}

/// What live play makes of the store's answer. Under the line only
/// where the whole of the range is: a store whose own lines do not fall
/// on it (a region's, which replace the app's) has not said.
@visibleForTesting
AgeVerdict verdictOf(AgeSignalsResult result) => switch (result.status) {
      AgeSignalsStatus.supervisedApprovalPending => AgeVerdict.awaitingParent,
      AgeSignalsStatus.supervisedApprovalDenied => AgeVerdict.parentDeclined,
      _ when (result.ageUpper ?? livePlayFrom) < livePlayFrom => AgeVerdict.tooYoung,
      _ => AgeVerdict.open,
    };
