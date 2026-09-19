/// A table event in bytes, for a data channel.
///
/// Every event a peer says is JSON on the way to a relay, because
/// NIP-01 is JSON and a relay is a stranger's machine that has to be
/// able to read what it stores. A data channel is neither: it carries
/// bytes between two clients that share this code, and nothing in
/// between has to understand them. Sending JSON down it costs three
/// separate expansions, and a hand measured at a sealed table of two
/// with two bot seats (`tool/wire_breakdown.dart`, 123,330 bytes of
/// event JSON) says what each is worth:
///
///  - **Base64.** Half the hand is the deal's cryptography — a shuffle
///    argument, reveal tokens, escrow — which is bytes, carried as
///    base64 because JSON has no byte string. 61,676 bytes of it,
///    where the bytes themselves are 46,257: a third again, for
///    nothing.
///  - **Hex.** An id, an author and a signature are 128 bytes of hash
///    and curve point written as 256 characters, on every one of the
///    hand's 76 events.
///  - **Structure.** Key names and punctuation, said again per event,
///    where a channel could agree on them once.
///
/// And two fields need not travel at all. A channel belongs to one
/// table, so the table id is known at both ends; and an id is the hash
/// of the rest, so it is recomputed rather than read — which is what
/// the parser does with it anyway (`events.dart`: an id that is not the
/// hash of the content is a rejected event). Nothing about what is
/// signed changes: the frame is a way of writing an event down, the
/// canonical bytes underneath it are the same bytes, and an event that
/// arrives over a channel has the same id it would have had over a
/// relay.
///
/// The encoding is self-describing, so it needs no schema per kind and
/// no version handshake beyond the first byte: values are tagged, and a
/// string that is exactly the base64 or lowercase hex of some bytes is
/// carried as those bytes and written back out the way it came in. The
/// round trip is checked while encoding — a string that does not come
/// back byte for byte is sent as a string — so a peer cannot make two
/// events with one id by writing base64 a second way.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'events.dart';

/// The first byte of every frame: this format, version 1. Chosen so
/// that a frame can never be mistaken for JSON, whose first byte at
/// the table is always `{`.
const frameMagic = 0xE0;

/// Body keys common enough to be worth a byte instead of their name.
/// Order is the wire; append only, never reorder or remove.
const frameKeys = <String>[
  'hand', 'turn', 'seat', 'step', 'event', 'card', 'round', 'side', 'about', 'reads',
  'jurors', 'snapshot', 'token', 'proof', 'proofs', 'deck', 'tokens', 'sealed', 'custody',
  'custodians', 'shareCustody', 'shareKeys', 'keys', 'lead', 'audit', 'piece', 'from', 'to',
  'id', 'table', 'author', 'kind', 'body', 'sig',
];

final _keyIndex = {for (var i = 0; i < frameKeys.length; i++) frameKeys[i]: i};

const _tagNull = 0;
const _tagFalse = 1;
const _tagTrue = 2;
const _tagInt = 3;
const _tagDouble = 4;
const _tagText = 5;
const _tagHex = 6;
const _tagBase64 = 7;
const _tagList = 8;
const _tagMap = 9;

/// Writes [event] — an event as `TableEvent.toJson` gives it — as a
/// frame, leaving out the table id and the event id. Returns null for
/// anything that is not shaped like an event, or whose table is not
/// [table]: the caller sends those as JSON, which is what the relay
/// lane does with everything.
Uint8List? encodeFrame(Map<String, Object?> event, {required String table}) {
  final author = event['author'];
  final kind = event['kind'];
  final sig = event['sig'];
  final body = event['body'];
  if (event['table'] != table || author is! String || kind is! String || sig is! String || body is! Map) return null;
  final kindIndex = EventKind.values.indexWhere((k) => k.name == kind);
  if (kindIndex < 0) return null;
  final w = _Writer()
    ..byte(frameMagic)
    ..byte(kindIndex);
  // A key and a signature are hex, so they go as the 32 and 64 bytes
  // they are — written as values rather than fixed fields, because
  // the simulator's stand-in signer has neither length (signing.dart)
  // and a format that only fits real keys could not be tested on it.
  _writeString(w, author);
  _writeString(w, sig);
  if (!_write(w, Map<String, Object?>.from(body))) return null;
  return w.take();
}

/// Reads a frame back into the map [TableEvent.parse] takes, with the
/// table id put back and the id recomputed from the content. Returns
/// null for a frame that is malformed or not this format — including
/// plain JSON, which a peer on an older build may still be sending.
Map<String, Object?>? decodeFrame(Uint8List frame, {required String table}) {
  try {
    if (frame.length < 6 || frame[0] != frameMagic) return null;
    final kindIndex = frame[1];
    if (kindIndex >= EventKind.values.length) return null;
    final kind = EventKind.values[kindIndex];
    final r = _Reader(frame, 2);
    final author = _read(r);
    final sig = _read(r);
    final body = _read(r);
    if (author is! String || sig is! String || body is! Map<String, Object?> || !r.done) return null;
    return {
      'id': TableEvent.idFor(table: table, author: author, kind: kind, body: body),
      'table': table,
      'author': author,
      'kind': kind.name,
      'body': body,
      'sig': sig,
    };
  } catch (_) {
    return null;
  }
}

// ---- values --------------------------------------------------------------

bool _write(_Writer w, Object? v) {
  if (v == null) {
    w.byte(_tagNull);
  } else if (v is bool) {
    w.byte(v ? _tagTrue : _tagFalse);
  } else if (v is int) {
    w..byte(_tagInt)..varint(_zig(v));
  } else if (v is double) {
    w..byte(_tagDouble)..float(v);
  } else if (v is String) {
    _writeString(w, v);
  } else if (v is List) {
    w..byte(_tagList)..varint(v.length);
    for (final e in v) {
      if (!_write(w, e)) return false;
    }
  } else if (v is Map) {
    w..byte(_tagMap)..varint(v.length);
    for (final e in v.entries) {
      if (e.key is! String) return false;
      _writeKey(w, e.key as String);
      if (!_write(w, e.value)) return false;
    }
  } else {
    // A value JSON has no room for is a bug upstream, not something to
    // guess at: the caller sends the event as JSON instead.
    return false;
  }
  return true;
}

Object? _read(_Reader r) {
  switch (r.byte()) {
    case _tagNull:
      return null;
    case _tagFalse:
      return false;
    case _tagTrue:
      return true;
    case _tagInt:
      return _zag(r.varint());
    case _tagDouble:
      return r.float();
    case _tagText:
      return utf8.decode(r.bytes(r.varint()));
    case _tagHex:
      final b = r.bytes(r.varint());
      return _hex(b, 0, b.length);
    case _tagBase64:
      return base64.encode(r.bytes(r.varint()));
    case _tagList:
      return [for (var i = r.varint(); i > 0; i--) _read(r)];
    case _tagMap:
      final n = r.varint();
      final m = <String, Object?>{};
      for (var i = 0; i < n; i++) {
        m[_readKey(r)] = _read(r);
      }
      return m;
    default:
      throw const FormatException('frame: unknown tag');
  }
}

/// A string that is the hex or base64 of some bytes goes as those
/// bytes — but only if writing them back gives the same string, so an
/// event's canonical form is never touched by having travelled.
void _writeString(_Writer w, String s) {
  if (s.length > 16) {
    final hex = _unhex(s, s.length ~/ 2);
    if (hex != null) {
      w..byte(_tagHex)..varint(hex.length)..raw(hex);
      return;
    }
    if (_base64ish(s)) {
      try {
        final b = base64.decode(s);
        if (base64.encode(b) == s) {
          w..byte(_tagBase64)..varint(b.length)..raw(b);
          return;
        }
      } catch (_) {
        // Not base64 after all; it goes as text.
      }
    }
  }
  final u = utf8.encode(s);
  w..byte(_tagText)..varint(u.length)..raw(u);
}

/// A known key is its index with the high bit set; anything else is a
/// length and its bytes. Keys are short, so the length is one byte and
/// a name never reaches 128 characters.
void _writeKey(_Writer w, String key) {
  final i = _keyIndex[key];
  if (i != null) {
    w.byte(0x80 | i);
    return;
  }
  final u = utf8.encode(key);
  if (u.length > 127) throw const FormatException('frame: key too long');
  w..byte(u.length)..raw(u);
}

String _readKey(_Reader r) {
  final b = r.byte();
  if (b & 0x80 != 0) {
    final i = b & 0x7f;
    if (i >= frameKeys.length) throw const FormatException('frame: unknown key');
    return frameKeys[i];
  }
  return utf8.decode(r.bytes(b));
}

// ---- hex, base64, varints ------------------------------------------------

const _hexDigits = '0123456789abcdef';

Uint8List? _unhex(String s, int expect) {
  if (s.length != expect * 2 || s.isEmpty) return null;
  final out = Uint8List(expect);
  for (var i = 0; i < expect; i++) {
    final hi = _nibble(s.codeUnitAt(i * 2));
    final lo = _nibble(s.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) return null;
    out[i] = hi << 4 | lo;
  }
  return out;
}

/// Lowercase only: uppercase hex would come back changed, and an event
/// that changes on the way is a different event.
int _nibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

String _hex(Uint8List b, int from, int length) {
  final out = StringBuffer();
  for (var i = from; i < from + length; i++) {
    out..write(_hexDigits[b[i] >> 4])..write(_hexDigits[b[i] & 0xf]);
  }
  return out.toString();
}

bool _base64ish(String s) {
  if (s.length % 4 != 0) return false;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final ok = (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x2b ||
        c == 0x2f ||
        (c == 0x3d && i >= s.length - 2);
    if (!ok) return false;
  }
  return true;
}

int _zig(int v) => v < 0 ? (-v << 1) - 1 : v << 1;
int _zag(int v) => v.isOdd ? -((v + 1) >> 1) : v >> 1;

class _Writer {
  // No copying: every list handed to [raw] is freshly made here and
  // never touched again. Bytes go through addByte rather than a
  // one-element buffer, which this builder would keep a reference to
  // rather than copy — every byte of the frame would then be the last
  // one written.
  final _out = BytesBuilder(copy: false);

  void byte(int b) => _out.addByte(b);

  void raw(List<int> b) => _out.add(b);

  void varint(int v) {
    while (v >= 0x80) {
      byte(v & 0x7f | 0x80);
      v >>= 7;
    }
    byte(v);
  }

  void float(double v) => _out.add(Uint8List.view((ByteData(8)..setFloat64(0, v)).buffer));

  Uint8List take() => _out.takeBytes();
}

class _Reader {
  _Reader(this.b, this.at);

  final Uint8List b;
  int at;

  bool get done => at == b.length;

  int byte() {
    if (at >= b.length) throw const FormatException('frame: short');
    return b[at++];
  }

  Uint8List bytes(int n) {
    if (at + n > b.length) throw const FormatException('frame: short');
    final out = Uint8List.sublistView(b, at, at + n);
    at += n;
    return out;
  }

  int varint() {
    var v = 0;
    var shift = 0;
    while (true) {
      final c = byte();
      v |= (c & 0x7f) << shift;
      if (c & 0x80 == 0) return v;
      shift += 7;
      if (shift > 56) throw const FormatException('frame: varint too long');
    }
  }

  double float() => ByteData.sublistView(bytes(8)).getFloat64(0);
}
