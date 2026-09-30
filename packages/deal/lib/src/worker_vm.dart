/// The VM's worker: an isolate with the cdylib open, making jobs one
/// at a time in the order they were sent.
library;

import 'dart:isolate';

import '../deal.dart';

DealWorker start({String? libraryPath}) => _IsolateWorker(libraryPath);

typedef _Waiting = ({void Function(Object answer) done, void Function(Object error) failed});

class _IsolateWorker implements DealWorker {
  _IsolateWorker(String? libraryPath) {
    _replies.listen(_onReply);
    Isolate.spawn(_main, (_replies.sendPort, libraryPath)).then((i) {
      if (_closed) i.kill();
      _isolate = i;
    }, onError: (Object e) => _dead('the isolate did not start: $e'));
  }

  final _replies = ReceivePort();
  final Map<int, _Waiting> _waiting = {};
  final List<(int, DealJob)> _unsent = [];
  SendPort? _jobs;
  Isolate? _isolate;
  Object? _death;
  bool _closed = false;
  int _next = 0;

  @override
  void run(DealJob job, {required void Function(Object answer) done, required void Function(Object error) failed}) {
    final death = _death;
    if (_closed || death != null) return failed(death ?? 'closed');
    final id = _next++;
    _waiting[id] = (done: done, failed: failed);
    final jobs = _jobs;
    if (jobs == null) {
      _unsent.add((id, job));
    } else {
      jobs.send((id, job));
    }
  }

  void _onReply(Object? m) {
    switch (m) {
      case SendPort jobs:
        _jobs = jobs;
        for (final u in _unsent) {
          jobs.send(u);
        }
        _unsent.clear();
      case (String why,):
        _dead(why);
      case (int id, Object answer, null):
        _waiting.remove(id)?.done(answer);
      case (int id, _, Object error):
        _waiting.remove(id)?.failed(error);
    }
  }

  void _dead(Object why) {
    _death = why;
    _unsent.clear();
    final waiting = List.of(_waiting.values);
    _waiting.clear();
    for (final w in waiting) {
      w.failed(why);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _jobs?.send(null);
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _replies.close();
    _waiting.clear();
    _unsent.clear();
  }
}

Future<void> _main((SendPort, String?) boot) async {
  final (reply, path) = boot;
  final DealCrypto crypto;
  try {
    crypto = await DealCrypto.load(libraryPath: path);
  } catch (e) {
    reply.send(('the deal did not load: $e',));
    return;
  }
  final jobs = ReceivePort();
  reply.send(jobs.sendPort);
  await for (final m in jobs) {
    if (m == null) break;
    final (int id, DealJob job) = m as (int, DealJob);
    try {
      reply.send((id, job.run(crypto), null));
    } catch (e) {
      reply.send((id, null, '$e'));
    }
  }
  jobs.close();
}
