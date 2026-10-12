/// Where a hand's bytes go, by event, by round, by field — and what
/// they would be if the wire compressed them. A working tool for
/// deciding what to shrink; juror_wire.dart is the headline number.
library;

import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

/// A real Schnorr signature is 128 hex characters where the
/// simulator's stand-in is 32.
const sigGap = 128 - FakeSigner.length;

/// The same gap in a frame, where a signature is the 64 bytes it is
/// rather than the hex of them (frame.dart).
const sigGapFramed = 64 - FakeSigner.length ~/ 2;

String shape(Object? v) {
  if (v is! String) return v.runtimeType.toString();
  if (RegExp(r'^[0-9a-f]+$').hasMatch(v) && v.length > 16) return 'hex(${v.length})';
  if (RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(v) && v.length > 16) return 'b64(${v.length})';
  return 'text(${v.length})';
}

void main() async {
  final crypto = await DealCrypto.load();
  final t = SimTable(humans: 2, seed: 7, crypto: crypto, jurors: 4);
  t.start();
  t.clock.runUntil(() => t.clients.first.game.handNumber >= 1, limitMs: 20 * 60 * 1000);
  final c = t.clients.first;
  final jurors = {for (final j in t.jurors) j.signer.publicKey};

  var whole = 0;
  var wholeGz = 0;
  var framed = 0;
  final byLabel = <String, List<int>>{};
  final fields = <String, int>{};
  final biggest = <(int, String, Map<String, Object?>)>[];
  for (final d in c.record) {
    final e = d.event;
    if (e.body['hand'] != 0) continue;
    final json = jsonEncode(e.toJson());
    final n = json.length + sigGap;
    whole += n;
    wholeGz += gzip.encode(utf8.encode(json)).length + sigGap;
    framed += encodeFrame(e.toJson(), table: e.table)!.length + sigGapFramed;
    final who = jurors.contains(e.author) ? 'juror' : 'player';
    final round = e.kind == EventKind.deal ? '.${e.body['round']}' : '';
    byLabel.putIfAbsent('${e.kind.name}$round $who', () => []).add(n);
    biggest.add((n, '${e.kind.name}$round $who', e.body));
    for (final f in e.body.entries) {
      fields['${e.kind.name}$round ${f.key}'] = (fields['${e.kind.name}$round ${f.key}'] ?? 0) + jsonEncode(f.value).length;
    }
  }

  print('--- 2 people, 2 bot seats the jury holds: hand 0, every table event ---');
  final labels = byLabel.keys.toList()..sort();
  for (final l in labels) {
    final v = byLabel[l]!..sort();
    print('${l.padRight(16)} n=${v.length.toString().padLeft(3)}  each=${v.first}..${v.last}  total=${v.fold(0, (a, b) => a + b)}');
  }
  print('the hand: $whole bytes, $wholeGz gzipped an event at a time (${(100 * wholeGz / whole).round()}%)');

  // An event at a time is the worst a compressor can do: every
  // message starts from nothing. A websocket that keeps its window
  // between messages (permessage-deflate with context takeover) is
  // nearer the stream, so measure that too — and measure what is left
  // once the base64 of curve points, which no compressor can touch, is
  // taken out of the count.
  final stream = <int>[];
  var payload = 0;
  for (final d in c.record) {
    final e = d.event;
    if (e.body['hand'] != 0) continue;
    final json = jsonEncode(e.toJson());
    stream.addAll(utf8.encode(json));
    for (final v in e.body.values) {
      final one = v is List ? v : [v];
      for (final x in one) {
        if (x is String && x.length > 64 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(x)) {
          payload += x.length;
        }
      }
    }
  }
  final structure = whole - payload;
  final streamGz = gzip.encode(stream).length;
  print('as one stream: $streamGz (${(100 * streamGz / whole).round()}%), '
      'so a window kept between messages is worth ${whole - streamGz} bytes');
  print('of the hand, $payload is base64 payload and $structure is structure');
  final bare = String.fromCharCodes(stream).replaceAll(RegExp(r'[A-Za-z0-9+/=]{64,}'), '');
  final withoutPayload = gzip.encode(utf8.encode(bare)).length;
  print('the structure alone, gzipped as a stream: $withoutPayload of $structure');

  // And the same hand as frames: what a data channel carries, where
  // nothing in the middle has to read it (frame.dart). No compressor,
  // no window, no CPU — the expansions are simply not made.
  print('as frames on a channel: $framed (${(100 * framed / whole).round()}%), '
      'so the channel framing is worth ${whole - framed} bytes a hand');

  print('\n--- the fields that carry it ---');
  final top = fields.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final f in top.take(12)) {
    print('${f.key.padRight(22)} ${f.value}');
  }

  biggest.sort((a, b) => b.$1.compareTo(a.$1));
  print('\n--- the biggest event, field by field ---');
  final (n, label, body) = biggest.first;
  print('$label, $n bytes');
  final parts = body.entries.toList()..sort((a, b) => jsonEncode(b.value).length.compareTo(jsonEncode(a.value).length));
  for (final p in parts.take(8)) {
    final v = p.value;
    final inner = v is List && v.isNotEmpty ? ' of ${v.length} × ${shape(v.first)}' : '';
    print('  ${p.key.padRight(12)} ${jsonEncode(v).length.toString().padLeft(6)}  ${shape(v)}$inner');
  }
  t.stop();
}
