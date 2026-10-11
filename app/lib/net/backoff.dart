/// Asking again after an ask that went unanswered: `first` the first
/// time, twice as long each time after that, up to `most`. The licence
/// and an account's list of devices are both asked for this way
/// (entitlement.dart, subscribe_page.dart).
library;

import 'dart:math' show min;

class Backoff {
  static const first = Duration(seconds: 2);
  static const most = Duration(minutes: 2);

  Duration _next = first;

  /// The wait before the next ask; the one after it twice as long, up
  /// to [most].
  Duration next() {
    final wait = _next;
    _next = Duration(milliseconds: min(_next.inMilliseconds * 2, most.inMilliseconds));
    return wait;
  }

  /// Answered, or about to be asked again at once: the waits start short
  /// again.
  void reset() => _next = first;
}
