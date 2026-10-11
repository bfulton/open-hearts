/// The channel's framing: every event of a real sealed hand written as
/// bytes and read back, and what it saves.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

/// The frame and the JSON must mean the same event, so the check is
/// the parser's own: both sides parse, and what comes out is equal
/// field for field — the id included, which the frame does not carry.
void sameEvent(Map<String, Object?> framed, TableEvent original) {
  final back = TableEvent.parse(framed);
  expect(back, isNotNull, reason: 'a frame must parse, id and signature and all');
  expect(back!.id, original.id);
  expect(back.table, original.table);
  expect(back.author, original.author);
  expect(back.kind, original.kind);
  expect(back.sig, original.sig);
  expect(jsonEncode(back.body), jsonEncode(original.body));
}

void main() {
  test('an event of every kind goes to bytes and back', () async {
    final crypto = await rememberedCrypto();
    final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: 4);
    t.start();
    t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 20 * 60 * 1000);
    final record = t.clients.first.record;
    expect(record, isNotEmpty);

    final kinds = <EventKind>{};
    var json = 0;
    var framed = 0;
    for (final d in record) {
      final e = d.event;
      final frame = encodeFrame(e.toJson(), table: e.table);
      expect(frame, isNotNull, reason: '${e.kind.name} should frame');
      sameEvent(decodeFrame(frame!, table: e.table)!, e);
      kinds.add(e.kind);
      json += jsonEncode(e.toJson()).length;
      framed += frame.length;
    }
    // The record is the hand's settled actions, so these three are
    // what it holds; the kinds around them are covered below.
    expect(kinds, containsAll([EventKind.deal, EventKind.pass, EventKind.play]));
    // The saving is the point of the format; a change that loses it is
    // a change worth noticing. The simulator's signatures are short,
    // so this is the conservative end of it.
    expect(framed, lessThan(json * 3 ~/ 4), reason: 'framed $framed of $json bytes of JSON');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('every kind frames, including the ones a settled record does not keep', () {
    final signer = FakeSigner('01');
    final other = FakeSigner('02');
    final witnessed = TableEvent.sign(other, table: 't', kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 2, 'card': '2C'});
    final bodies = {
      EventKind.pass: {'hand': 0, 'turn': 1, 'seat': 1, 'cards': ['QS', '2C', 'AH']},
      EventKind.play: {'hand': 0, 'turn': 4, 'seat': 1, 'card': 'QS'},
      EventKind.leave: {'hand': 0, 'turn': 4, 'seat': 1, 'step': 3},
      EventKind.boot: {'hand': 0, 'turn': 4, 'seat': 1},
      EventKind.absent: {'hand': 0, 'turn': 4, 'seat': 1},
      EventKind.witness: {'hand': 0, 'turn': 4, 'seat': 2, 'event': witnessed.id},
      EventKind.heartbeat: {'hand': 0, 'step': 7, 'reads': ['wss://a', 'wss://b']},
      EventKind.jury: {'hand': 0, 'turn': -16, 'seat': 1, 'jurors': [other.publicKey], 'snapshot': [signer.publicKey, other.publicKey]},
      EventKind.serve: {'hand': 0, 'step': 7, 'serving': [0], 'reads': ['wss://a']},
      EventKind.appeal: {'hand': 0, 'turn': 4, 'seat': 1},
      EventKind.verdict: {'hand': 0, 'turn': 4, 'seat': 1, 'side': 'action', 'event': witnessed.toJson()},
      EventKind.deal: {'hand': 0, 'turn': -16, 'seat': 1, 'round': 0, 'keys': 'AAECAwQFBgcICQoLDA0ODw=='},
      EventKind.release: {'hand': 0, 'about': 2, 'piece': 'AAECAwQFBgcICQoLDA0ODw=='},
      EventKind.topup: {
        'hand': 0,
        'about': 2,
        'at': 5,
        'have': [1, 3],
        'from': 1,
        'holder': other.publicKey,
        'part': 'AAECAwQFBgcICQoLDA0ODw==',
      },
      EventKind.ended: {'hand': 0, 'turn': 59, 'seat': 3, 'vote': true},
      EventKind.escrow: {'hand': 0, 'turn': 9, 'seat': 3},
    };
    expect(bodies.keys, containsAll(EventKind.values), reason: 'a new kind wants a line here');
    for (final e in bodies.entries) {
      final ev = TableEvent.sign(signer, table: 't', kind: e.key, body: e.value);
      final frame = encodeFrame(ev.toJson(), table: 't');
      expect(frame, isNotNull, reason: e.key.name);
      sameEvent(decodeFrame(frame!, table: 't')!, ev);
    }
  });

  test('a frame carries the table id nowhere and the id is recomputed', () {
    final signer = FakeSigner('aa');
    final e = TableEvent.sign(signer, table: 'a-table', kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 1, 'card': 'QS'});
    final frame = encodeFrame(e.toJson(), table: 'a-table')!;
    expect(utf8.decode(frame, allowMalformed: true), isNot(contains('a-table')));
    expect(decodeFrame(frame, table: 'a-table')!['id'], e.id);
    // Read as another table's, the content hashes differently, so the
    // signature no longer belongs to it and the parser says no.
    expect(TableEvent.parse(decodeFrame(frame, table: 'another')!), isNull);
  });

  test('a string that would not come back the same goes as a string', () {
    final signer = FakeSigner('bb');
    // Uppercase hex and non-canonical base64: both would be rewritten
    // by a codec that decoded them, which would change the event's id.
    for (final odd in ['DEADBEEFDEADBEEFDEADBEEF', 'AAAAAAAAAAAAAAAAAAAAAAB=']) {
      final e = TableEvent.sign(signer, table: 't', kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 1, 'card': odd});
      sameEvent(decodeFrame(encodeFrame(e.toJson(), table: 't')!, table: 't')!, e);
    }
  });

  test('bodies of every shape survive', () {
    final signer = FakeSigner('cc');
    final bodies = <Map<String, Object?>>[
      {'hand': 0, 'turn': -16, 'seat': 3, 'nothing': null, 'yes': true, 'no': false},
      {'hand': 1, 'list': <Object?>[1, 'two', null, <Object?>[], <String, Object?>{}], 'deep': {'a': {'b': {'c': 'd'}}}},
      {'hand': 2, 'big': 1 << 40, 'negative': -(1 << 40), 'fraction': 0.5},
      {'hand': 3, 'unicode': 'a table of ♥ and ♠ — and a dash', 'empty': ''},
      {'hand': 4, 'b64': base64.encode(List<int>.generate(300, (i) => (i * 37) & 0xff))},
      {'hand': 5, 'unnamed key not in the dictionary': 'x', 'hex': '0123456789abcdef0123456789abcdef'},
    ];
    for (final odd in bodies) {
      // A deal step's own fields, so that it parses as one, under the
      // shapes being tried.
      final body = {'turn': -16, 'seat': 3, 'round': 0, ...odd};
      final e = TableEvent.sign(signer, table: 't', kind: EventKind.deal, body: body);
      final frame = encodeFrame(e.toJson(), table: 't');
      expect(frame, isNotNull, reason: '$body');
      sameEvent(decodeFrame(frame!, table: 't')!, e);
    }
  });

  test('a verdict carrying a whole event survives', () async {
    final signer = FakeSigner('dd');
    final inner = TableEvent.sign(FakeSigner('ee'), table: 't', kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 2, 'card': '2C'});
    final e = TableEvent.sign(signer,
        table: 't', kind: EventKind.verdict, body: {'hand': 0, 'turn': 4, 'seat': 2, 'side': 'action', 'event': inner.toJson()});
    final back = TableEvent.parse(decodeFrame(encodeFrame(e.toJson(), table: 't')!, table: 't')!)!;
    sameEvent(back.toJson(), e);
    expect(back.ruled?.id, inner.id);
  });

  test('anything that is not a frame of this table is refused both ways', () {
    final signer = FakeSigner('ff');
    final e = TableEvent.sign(signer, table: 't', kind: EventKind.play, body: {'hand': 0, 'turn': 4, 'seat': 1, 'card': 'QS'});
    // Not this table's, so the caller sends it as JSON instead.
    expect(encodeFrame(e.toJson(), table: 'other'), isNull);
    // Not an event at all: presence and signalling do not ride here.
    expect(encodeFrame({'hello': 'there'}, table: 't'), isNull);
    // JSON arriving where a frame was expected is not mistaken for one.
    expect(decodeFrame(Uint8List.fromList(utf8.encode(jsonEncode(e.toJson()))), table: 't'), isNull);
    // Truncated, and corrupt past the header.
    final frame = encodeFrame(e.toJson(), table: 't')!;
    expect(decodeFrame(Uint8List.sublistView(frame, 0, frame.length - 1), table: 't'), isNull);
    final bent = Uint8List.fromList(frame)..[frame.length - 2] ^= 0xff;
    final read = decodeFrame(bent, table: 't');
    if (read != null) expect(TableEvent.parse(read), isNull, reason: 'a bent frame is not a signed event');
  });
}
