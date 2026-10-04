import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:table/table.dart';

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
/// gone when the page stops listening, and when the verdict is in.
Stream<RecordCheck> checkRecord(GameRecord record) {
  late final StreamController<RecordCheck> out;
  _Worker? worker;
  void end(RecordCheck last) {
    if (out.isClosed) return;
    out.add(last);
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
            end(const RecordChecked(ok: false));
          }
        }).toJS;
        // The worker's script not served, or broken: not checked here.
        w.onerror = ((JSAny? _) => end(const RecordChecked(ok: false))).toJS;
        w.postMessage(jsonEncode(record.toJson()).toJS);
      } catch (_) {
        end(const RecordChecked(ok: false));
      }
    },
    onCancel: () => worker?.terminate(),
  );
  return out.stream;
}
