/// The errors the app meets on the web, told to New Relic's browser
/// agent (web/observability.js, privacy page: "the errors it meets").
///
/// A release build shows a widget that throws as a plain grey box and
/// says why only in the console, which on a phone nobody can read: a
/// whole table went grey that way, with nothing to go on. So every
/// Flutter error, and every uncaught one, is sent as well as printed,
/// with its stack and the build. A few to a page load: one that throws
/// in a build throws every frame.
library;

import 'package:flutter/foundation.dart';

import '../build_info.dart' show buildTag;
import 'report_error_io.dart' if (dart.library.js_interop) 'report_error_web.dart' as platform;

/// How many are sent from one page load.
const reportedAtMost = 20;
var _reported = 0;

/// Sends [error] and [stack] on, where the page has the agent. [where]
/// is what the framework says it was doing.
void reportError(Object error, StackTrace? stack, {String? where}) {
  if (_reported >= reportedAtMost) return;
  _reported++;
  platform.notice('$error', '${stack ?? ''}', {
    'where': where ?? '',
    'build': buildTag,
  });
}

/// Tells [reportError] of every Flutter error, after the framework's own
/// handling (printed to the console, as before), and of every error
/// nothing else caught.
void reportErrors() {
  final presented = FlutterError.onError;
  FlutterError.onError = (details) {
    presented?.call(details);
    reportError(details.exception, details.stack, where: details.context?.toDescription());
  };
  final uncaught = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    reportError(error, stack, where: 'uncaught');
    return uncaught?.call(error, stack) ?? false;
  };
}
