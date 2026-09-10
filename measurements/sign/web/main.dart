/// Signs and verifies a batch of Nostr events and reports the time,
/// in the browser. Run by bench.mjs; read the README.
library;

import 'dart:js_interop';

import 'package:table/table.dart';

@JS('report')
external void report(String json);

void main() {
  final signer = SchnorrSigner.generate();
  final events = <NostrEvent>[];
  var t0 = DateTime.now();
  for (var i = 0; i < 20; i++) {
    events.add(NostrEvent.sign(signer, kind: TableKinds.table, content: '{"n":$i}', tags: [
      ['t', 'bench']
    ]));
  }
  final signMs = DateTime.now().difference(t0).inMicroseconds / 1000 / events.length;
  t0 = DateTime.now();
  var ok = 0;
  for (final e in events) {
    if (NostrEvent.parse(e.toJson()) != null) ok++;
  }
  final verifyMs = DateTime.now().difference(t0).inMicroseconds / 1000 / events.length;
  report('{"sign_ms":$signMs,"verify_ms":$verifyMs,"verified":$ok,"of":${events.length}}');
}
