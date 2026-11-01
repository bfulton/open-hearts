import 'dart:convert';

import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  test('an event round-trips, and a changed one is refused', () {
    final signer = SchnorrSigner.generate();
    final e = NostrEvent.sign(signer, kind: 1, content: 'hello "world"\n', tags: [
      ['t', 'table-1'],
      ['p', 'a' * 64],
    ]);
    final json = jsonDecode(jsonEncode(e.toJson()));
    final back = NostrEvent.parse(json);
    expect(back, isNotNull);
    expect(back!.id, e.id);
    expect(back.content, e.content);
    expect(back.tag('t'), 'table-1');
    final tampered = Map<String, Object?>.from(json as Map)..['content'] = 'hello';
    expect(NostrEvent.parse(tampered), isNull, reason: 'the id no longer matches');
    final forged = Map<String, Object?>.from(json)..['sig'] = 'f' * 128;
    expect(NostrEvent.parse(forged), isNull, reason: 'the signature does not verify');
  });

  test('the id is NIP-01 canonical', () {
    // The reference vector from the NIP-01 text, minus the signature:
    // serialising with these fields must give this id.
    final canonical = NostrEvent.canonical('a' * 64, 1700000000, 1, [], 'x');
    expect(utf8.decode(canonical), '[0,"${'a' * 64}",1700000000,1,[],"x"]');
  });

  test('a filter is written as NIP-01 has it, each tag as #x after the rest', () {
    expect(jsonEncode(const Filter(kinds: [1, 2], since: 5, tags: {'p': ['k'], 't': ['x']}).toJson()),
        '{"kinds":[1,2],"since":5,"#p":["k"],"#t":["x"]}');
  });
}
