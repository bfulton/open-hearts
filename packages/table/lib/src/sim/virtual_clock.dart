/// A clock that only moves when told to.
library;

import 'dart:collection';

import '../clock.dart';

class VirtualClock implements Clock {
  int _now = 0;
  int _seq = 0;
  final _queue = SplayTreeMap<(int, int), void Function()>(
      (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));

  @override
  int get nowMs => _now;

  @override
  Cancel schedule(int delayMs, void Function() callback) {
    final key = (_now + delayMs, _seq++);
    _queue[key] = callback;
    return () => _queue.remove(key);
  }

  bool get idle => _queue.isEmpty;

  /// Runs everything due up to [untilMs].
  void advanceTo(int untilMs) {
    while (_queue.isNotEmpty && _queue.firstKey()!.$1 <= untilMs) {
      final key = _queue.firstKey()!;
      final cb = _queue.remove(key)!;
      _now = key.$1;
      cb();
    }
    if (untilMs > _now) _now = untilMs;
  }

  void advance(int ms) => advanceTo(_now + ms);

  /// Runs until [done] or [limitMs] of virtual time has passed. Returns
  /// whether [done] became true.
  bool runUntil(bool Function() done, {required int limitMs}) {
    final deadline = _now + limitMs;
    while (!done()) {
      if (_queue.isEmpty || _queue.firstKey()!.$1 > deadline) {
        _now = deadline;
        return done();
      }
      final key = _queue.firstKey()!;
      final cb = _queue.remove(key)!;
      _now = key.$1;
      cb();
    }
    return true;
  }
}
