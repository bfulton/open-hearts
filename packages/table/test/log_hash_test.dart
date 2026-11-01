/// The log's running hash (log.dart, LogHash), held to the cases in
/// log_hash.vectors.json, beside this file. The house signs the hash with
/// a game's result and the service checks a kept game against it with
/// its own fold (service/functions/records.mjs, logHashes), which
/// service/functions/records.test.mjs holds to the same cases, so that
/// the two cannot drift apart without one of them saying so.
library;

import 'dart:convert';
import 'dart:io';

import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  final vectors = jsonDecode(File('test/log_hash.vectors.json').readAsStringSync()) as Map<String, Object?>;
  final cases = (vectors['cases'] as List).cast<Map<String, Object?>>();

  test('the hash before any entry is the hash of the tag', () {
    expect(LogHash().value, vectors['start']);
    expect(LogHash().count, 0);
  });

  for (final c in cases) {
    test('${c['name']}: the hash after each entry is the one the cases give', () {
      final log = (c['log'] as List).cast<Map<String, Object?>>();
      final hashes = (c['hashes'] as List).cast<String>();
      expect(hashes, hasLength(log.length + 1));
      final hash = LogHash();
      expect(hash.value, hashes.first);
      for (final (i, raw) in log.indexed) {
        // The entry as the referee writes it reads, and writes itself
        // out as it was: the cases are entries, not made-up text.
        final entry = LogEntry.parse(raw);
        expect(entry, isNotNull, reason: 'entry $i reads');
        expect(entry!.toJson(), raw, reason: 'entry $i is written as it came');
        hash.add(entry);
        expect(hash.value, hashes[i + 1], reason: 'after entry $i');
        expect(hash.count, i + 1);
      }
    });
  }

  test('the cases hold an event that reads, a connection each way, a tick and an event no side reads', () {
    final entries = [
      for (final c in cases)
        for (final raw in (c['log'] as List).cast<Map<String, Object?>>()) LogEntry.parse(raw)!,
    ];
    expect(entries.any((e) => e.event != null), isTrue);
    expect(entries.any((e) => e.up != null), isTrue);
    expect(entries.any((e) => e.down != null), isTrue);
    expect(entries.any((e) => e.isTick), isTrue);
    expect(entries.any((e) => e.unread != null), isTrue);
  });
}
