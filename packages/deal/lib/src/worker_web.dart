/// The browser's worker: a Web Worker running `deal_worker.js` from
/// beside the app, with its own instance of the same `deal.wasm`,
/// making jobs one at a time in the order they were sent.
library;

import 'dart:js_interop';

import '../deal.dart';

/// [libraryPath] names the wasm, relative to the worker's script, as
/// [DealCrypto.load]'s does relative to the page.
DealWorker start({String? libraryPath}) {
  final query = libraryPath == null ? '' : '?wasm=${Uri.encodeQueryComponent(libraryPath)}';
  return _WebWorker(_Worker('deal_worker.js$query'.toJS));
}

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(JSString url);
  external void postMessage(JSAny? message);
  external set onmessage(JSFunction? f);
  external set onerror(JSFunction? f);
  external void terminate();
}

extension type _Event._(JSObject _) implements JSObject {
  external _Reply get data;
}

extension type _ErrorEvent._(JSObject _) implements JSObject {
  external JSString? get message;
  external void preventDefault();
}

extension type _Job._(JSObject _) implements JSObject {
  external factory _Job({JSNumber id, JSString op, JSArray<JSUint8Array> args});
}

extension type _Reply._(JSObject _) implements JSObject {
  external JSNumber get id;
  external JSArray<JSUint8Array>? get out;
  external JSString? get error;
}

typedef _Waiting = ({DealJob job, void Function(Object answer) done, void Function(Object error) failed});

class _WebWorker implements DealWorker {
  _WebWorker(this._worker) {
    _worker.onmessage = ((_Event e) => _onReply(e.data)).toJS;
    // A script that is not there, or does not parse, is an error on
    // the worker and nothing else: every job waiting is made at home.
    _worker.onerror = ((_ErrorEvent e) {
      e.preventDefault();
      _dead('the deal worker failed: ${e.message?.toDart ?? 'no reason given'}');
    }).toJS;
  }

  final _Worker _worker;
  final Map<int, _Waiting> _waiting = {};
  Object? _death;
  int _next = 0;

  @override
  void run(DealJob job, {required void Function(Object answer) done, required void Function(Object error) failed}) {
    final death = _death;
    if (death != null) return failed(death);
    final id = _next++;
    _waiting[id] = (job: job, done: done, failed: failed);
    // Copied across, not transferred: the session goes on holding the
    // bytes a job was made from, and a transferred buffer is gone.
    _worker.postMessage(_Job(id: id.toJS, op: job.op.toJS, args: [for (final a in job.args) a.toJS].toJS));
  }

  void _onReply(_Reply r) {
    final w = _waiting.remove(r.id.toDartInt);
    if (w == null) return;
    final error = r.error;
    final out = r.out;
    if (error != null || out == null) return w.failed(error?.toDart ?? 'no answer');
    final Object answer;
    try {
      answer = w.job.answerFrom([for (final b in out.toDart) b.toDart]);
    } catch (e) {
      return w.failed(e);
    }
    w.done(answer);
  }

  void _dead(Object why) {
    _death = why;
    final waiting = List.of(_waiting.values);
    _waiting.clear();
    for (final w in waiting) {
      w.failed(why);
    }
  }

  @override
  void close() {
    _death ??= 'closed';
    _waiting.clear();
    _worker.terminate();
  }
}
