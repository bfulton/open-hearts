/// Time, as the protocol sees it.
///
/// The client never reads a wall clock: it asks a [Clock] for now and
/// for callbacks later, so the same code runs in real time in the app
/// and in a simulation that can play a whole game in milliseconds.
library;

abstract class Clock {
  /// Milliseconds since some epoch. Only differences matter.
  int get nowMs;

  /// Runs [callback] after [delayMs]. The handle cancels it.
  Cancel schedule(int delayMs, void Function() callback);
}

typedef Cancel = void Function();

/// Real time, for the app.
class WallClock implements Clock {
  final _epoch = DateTime.now();

  @override
  int get nowMs => DateTime.now().difference(_epoch).inMilliseconds;

  @override
  Cancel schedule(int delayMs, void Function() callback) {
    final timer = Future<void>.delayed(Duration(milliseconds: delayMs));
    var cancelled = false;
    timer.then((_) {
      if (!cancelled) callback();
    });
    return () => cancelled = true;
  }
}
