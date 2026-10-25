/// The App Store's and Google Play's review prompts, through the
/// in_app_review plugin: StoreKit's on an iPhone, the Play In-App Review
/// API on Android.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';

import 'store_review.dart';

StoreReview? storeReviewHere() => Platform.isIOS || Platform.isAndroid ? PhoneReview() : null;

/// The phone's own store, asked through the plugin.
class PhoneReview implements StoreReview {
  @override
  Future<void> request() async {
    try {
      await InAppReview.instance.requestReview();
    } on Exception catch (e) {
      // Nothing to put it up with: an Android phone without Google
      // Play, or a Play that did not answer.
      debugPrint('review: the store did not ask: $e');
    }
  }
}
