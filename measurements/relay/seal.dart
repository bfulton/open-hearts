// What it costs to seal what goes over a relay:
//
//   cd measurements/relay
//   dart pub get
//   dart run seal.dart                                # the VM: phones
//   dart compile js -O2 -o seal.js seal.dart && node seal.js   # the web
//
// Anything point to point on a relay is sealed to its recipient, since
// a public relay carries the event and the relay is not a friend: the
// app already does this for WebRTC signalling with NIP-44 v2
// (packages/table/lib/src/nip44.dart), and anything else addressed to
// one party — doc 04's computation to a juror, say — would be sealed
// the same way. NIP-44 is Dart, not wasm, so the web app pays dart2js
// for it, which measurements/sign showed is a tenfold penalty on this
// kind of code.
//
// The sizes stop at 65535 because that is NIP-44's own limit on a
// plaintext. Content is base64 on this wire, so the largest *payload*
// one sealed event can carry is three quarters of that.

import 'dart:convert';
import 'dart:typed_data';

import 'package:table/table.dart';

void main() {
  final key = Nip44.conversationKey(Uint8List.fromList(List.generate(32, (i) => (i * 7 + 13) & 0xff)));
  print('  plaintext     encrypt     decrypt   encrypt MB/s   decrypt MB/s');
  for (final bytes in [256, 1024, 16384, 65535]) {
    final text = base64.encode(Uint8List(bytes * 3 ~/ 4)).substring(0, bytes);
    final rounds = bytes > 16384 ? 200 : 1000;
    // Warm whatever the runtime wants to warm before anything is timed.
    for (var i = 0; i < 20; i++) Nip44.decrypt(key, Nip44.encrypt(key, text));

    final sw = Stopwatch()..start();
    var sealed = '';
    for (var i = 0; i < rounds; i++) sealed = Nip44.encrypt(key, text);
    sw.stop();
    final enc = sw.elapsedMicroseconds / rounds / 1000;

    final sw2 = Stopwatch()..start();
    for (var i = 0; i < rounds; i++) Nip44.decrypt(key, sealed);
    sw2.stop();
    final dec = sw2.elapsedMicroseconds / rounds / 1000;

    String mb(double ms) => (bytes / 1048576 / (ms / 1000)).toStringAsFixed(1).padLeft(13);
    print('  ${bytes.toString().padLeft(9)}  ${enc.toStringAsFixed(3).padLeft(8)} ms  ${dec.toStringAsFixed(3).padLeft(8)} ms  ${mb(enc)}  ${mb(dec)}');
  }

  // What one sealed event can carry. Bytes that are not text are
  // base64 inside the message, the message is the plaintext, and the
  // sealed plaintext is base64 again: two expansions, not one, and
  // NIP-44's cap lands on the message rather than on the payload.
  String message(int raw) => jsonEncode({'d': base64.encode(Uint8List(raw))});
  var raw = 3 * ((Nip44.maxPlaintext - 8) ~/ 4);
  while (message(raw).length > Nip44.maxPlaintext) raw -= 3;
  final sealed = Nip44.encrypt(key, message(raw));
  print('');
  print('  the most one sealed event carries: $raw bytes of payload');
  print('    ${message(raw).length} bytes of message, ${sealed.length} sealed'
      ' — ${(sealed.length / raw).toStringAsFixed(2)}x before the envelope');
}
