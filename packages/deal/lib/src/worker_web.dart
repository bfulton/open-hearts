/// The browser's worker: a Web Worker running `deal_worker.js` from
/// beside the app, with its own instance of the same `deal.wasm`,
/// making jobs one at a time in the order they were sent.
library;

import 'dart:async';
import 'dart:js_interop';

import '../deal.dart';

/// Fetches the worker's script and the wasm, once, now — [libraryPath]
/// names the wasm as [DealCrypto.load]'s does — and gives back a way to
/// start workers from them: the script as a blob, the wasm handed over
/// in a message. A worker started later, to replace one that failed,
/// fetches nothing. An error, saying why, if either is not served.
Future<Future<DealWorker> Function()> spawner({String? libraryPath}) async {
  final script = await _fetched('deal_worker.js');
  final wasm = await _fetched(libraryPath ?? 'deal.wasm');
  final source = (await script.text().toDart).toDart;
  final bytes = (await wasm.arrayBuffer().toDart).toDart.asUint8List();
  final url = _objectUrl(_Blob([source.toJS].toJS, _BlobType(type: 'text/javascript'.toJS)));
  return () {
    final w = _WebWorker(_Worker(url));
    // Copied across, not transferred: kept here for the next worker.
    w._worker.postMessage(_Init(wasm: bytes.toJS));
    return w._ready.future;
  };
}

Future<_Response> _fetched(String url) async {
  final r = await _fetch(url.toJS).toDart;
  if (!r.ok) throw StateError('$url is not served (${r.status})');
  return r;
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSString> text();
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts, _BlobType options);
}

extension type _BlobType._(JSObject _) implements JSObject {
  external factory _BlobType({JSString type});
}

@JS('URL.createObjectURL')
external JSString _objectUrl(_Blob blob);

extension type _Init._(JSObject _) implements JSObject {
  external factory _Init({JSUint8Array wasm});
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
  external JSBoolean? get ready;
  external JSString? get unloaded;
  external JSNumber? get id;
  external JSArray<JSUint8Array>? get out;
  external JSString? get error;
}

typedef _Waiting = ({DealJob job, void Function(Object answer) done, void Function(Object error) failed});

class _WebWorker implements DealWorker {
  _WebWorker(this._worker) {
    _worker.onmessage = ((_Event e) => _onReply(e.data)).toJS;
    // A script that is not there, or does not parse, is an error on
    // the worker and nothing else.
    _worker.onerror = ((_ErrorEvent e) {
      e.preventDefault();
      _dead('the deal worker failed: ${e.message?.toDart ?? 'no reason given'}');
    }).toJS;
  }

  final _Worker _worker;
  final _ready = Completer<DealWorker>();

  @override
  bool get dead => _death != null;
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
    if (r.ready?.toDart ?? false) {
      if (!_ready.isCompleted) _ready.complete(this);
      return;
    }
    final unloaded = r.unloaded;
    if (unloaded != null) return _dead(unloaded.toDart);
    final id = r.id;
    if (id == null) return;
    final w = _waiting.remove(id.toDartInt);
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
    if (!_ready.isCompleted) {
      _ready.completeError(why);
      _worker.terminate();
    }
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
