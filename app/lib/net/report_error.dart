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

/// Where a test hears what would have gone to New Relic, in its place.
@visibleForTesting
void Function(String message, Map<String, String> attributes)? noticed;

void _notice(String message, String stack, Map<String, String> attributes) {
  final heard = noticed;
  if (heard != null) return heard(message, attributes);
  platform.notice(message, stack, attributes);
}

/// Sends [error] and [stack] on, where the page has the agent. [where]
/// is what the framework says it was doing.
void reportError(Object error, StackTrace? stack, {String? where}) {
  if (_reported >= reportedAtMost) return;
  _reported++;
  _notice('$error', '${stack ?? ''}', {
    'where': where ?? '',
    'build': buildTag,
  });
}

/// Sends on a live game lost to the line, or a line down for long at a
/// live table: [what] happened, with [account], the table as this
/// device saw it (TableClient.lineAccount in packages/table), and
/// [line], its transport's. Neither holds a key, a card or a name. The
/// first eight characters of the table's id go with them, so that the
/// operator can lay the device's side beside the relay's and the
/// backup jurors' logs of the same table (docs/how-to/look-into-a-lost-game.md).
/// Counted with the errors, a few to a page load.
void reportLine(String what, {required String table, required String account, required String line}) {
  if (_reported >= reportedAtMost) return;
  _reported++;
  final short = table.length > 8 ? table.substring(0, 8) : table;
  debugPrint('line: $what at $short: $account; $line');
  _notice('live: $what', '', {
    'where': 'live table',
    'table': short,
    'seen': account,
    'line': line,
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
