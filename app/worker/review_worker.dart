/// A kept game checked off the page's thread (net/record_check.dart).
///
/// Compiled on its own to `review_worker.js` beside the app (deploy.sh,
/// e2e/build.sh): a Web Worker with its own deal.wasm and schnorr.wasm,
/// fetched from beside it. The page sends the record as it came from the
/// service, and the service's key, `{record: text, service: key}`; the
/// worker answers each hand as its check is done, `{hand: …}`, and then
/// the verdict, `{done: {ok, reason, winners}}` — or `{error: why}` when
/// it could not check at all. The page's screen never waits on it.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:deal/deal.dart';
import 'package:open_hearts/crypto/schnorr_web.dart';
import 'package:open_hearts/net/record_check.dart' show readRecord;
import 'package:table/table.dart';

@JS('self')
external _Scope get _self;

extension type _Scope._(JSObject _) implements JSObject {
  external set onmessage(JSFunction f);
  external void postMessage(JSAny? message);
}

extension type _Message._(JSObject _) implements JSObject {
  external JSAny? get data;
}

void _say(Map<String, Object?> m) => _self.postMessage(jsonEncode(m).toJS);

void main() {
  _self.onmessage = ((_Message e) {
    _check((e.data as JSObject).dartify() as Map);
  }).toJS;
}

Future<void> _check(Map<Object?, Object?> asked) async {
  try {
    await installFastSchnorr();
    final crypto = await DealCrypto.load();
    // The service the page checks seats' licences by (packages/table,
    // licence.dart): the page's own, handed over with the record.
    if (asked['service'] case final String service when RegExp(r'^[0-9a-f]{64}$').hasMatch(service)) licenceService = service;
    // Read here, every event and every signature, as the page left it
    // to be (net/record_check.dart, KeptGame).
    final (:record, :failed) = readRecord(asked['record'] as String);
    if (record == null) {
      if (failed?.reason == null) return _say({'error': 'not a record'});
      return _say({
        'done': {'ok': false, 'reason': failed!.reason, 'winners': const <int>[]},
      });
    }
    final v = verifyRecord(
      record.spec,
      record.record,
      juries: record.juries,
      releases: record.releases,
      crypto: crypto,
      allowPartial: true,
      replay: TableReplay(onHand: (h) => _say({'hand': h.toJson()})),
    );
    _say({
      'done': {'ok': v.ok, 'reason': v.ok ? null : v.reason, 'winners': v.winners},
    });
  } catch (e) {
    _say({'error': '$e'});
  }
}
