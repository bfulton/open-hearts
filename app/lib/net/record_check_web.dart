import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:table/table.dart';

import 'licence.dart' show houseKey;
import 'record_check.dart';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(JSString url);
  external set onmessage(JSFunction f);
  external set onerror(JSFunction f);
  external void postMessage(JSAny? message);
  external void terminate();
}

extension type _Message._(JSObject _) implements JSObject {
  external JSAny? get data;
}

/// In a worker of its own (worker/review_worker.dart), beside the app;
/// gone when the page stops listening, and when the verdict is in. A
/// check the worker could not make ends in an error, which the page
/// reports (review_page.dart), as a check that throws does off the web.
Stream<RecordCheck> checkRecord(KeptGame game) {
  late final StreamController<RecordCheck> out;
  _Worker? worker;
  void end(RecordCheck last) {
    if (out.isClosed) return;
    out.add(last);
    out.close();
    worker?.terminate();
  }

  void fail(Object why) {
    if (out.isClosed) return;
    out.addError(StateError('record check: $why'));
    out.close();
    worker?.terminate();
  }

  out = StreamController<RecordCheck>(
    onListen: () {
      try {
        final w = worker = _Worker('review_worker.js'.toJS);
        w.onmessage = ((_Message e) {
          final m = jsonDecode((e.data as JSString).toDart) as Map<String, Object?>;
          if (m['hand'] case final Map<String, Object?> hand) {
            if (!out.isClosed) out.add(HandChecked(TableReplayHand.fromJson(hand)));
          } else if (m['done'] case final Map<String, Object?> done) {
            end(RecordChecked(
              ok: done['ok'] == true,
              reason: done['reason'] as String?,
              winners: [for (final s in done['winners'] as List? ?? const []) s as int],
            ));
          } else {
            fail(m['error'] ?? 'an answer it does not read');
          }
        }).toJS;
        // The worker's script not served, or broken.
        w.onerror = ((JSAny? _) => fail('review_worker.js did not run')).toJS;
        // The record as it came, for the worker to read — not read here
        // and written out again — with the service whose word makes each
        // seat an account's, and the house this build plays with: the
        // worker is a program of its own, and checks the game by them.
        w.postMessage({'record': game.text, 'service': licenceService, 'house': houseKey}.jsify());
      } catch (e) {
        fail(e);
      }
    },
    onCancel: () => worker?.terminate(),
  );
  return out.stream;
}
