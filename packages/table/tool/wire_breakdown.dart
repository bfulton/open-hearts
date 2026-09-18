/// Where a hand's bytes go, by event, by round, by field — and what
/// they would be if the wire compressed them. A working tool for
/// deciding what to shrink; juror_wire.dart is the headline number.
library;

import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

/// A real Schnorr signature is 128 hex characters where the
/// simulator's stand-in is 32.
const sigGap = 128 - FakeSigner.length;

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
  print('the hand: $whole bytes, $wholeGz gzipped (${(100 * wholeGz / whole).round()}%)');

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
