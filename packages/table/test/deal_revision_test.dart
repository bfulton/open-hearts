/// The revision of the deal's messages a sealed table is played by
/// (spec.dart, `dealRevision`): in the spec, so in its id; a table plays
/// its own build's and no other, a verifier of kept games reads the
/// earlier ones too, and nothing but the spec says which.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

void main() {
  late DealCrypto crypto;
  setUpAll(() async => crypto = await rememberedCrypto());

  final p0 = FakeSigner('revision p0');
  final p1 = FakeSigner('revision p1');
  final house = FakeSigner('revision house').publicKey;

  TableSpec specOf({bool sealed = true, int? deal}) => TableSpec(
        seed: 5,
        salt: newSalt(),
        seats: [HumanSeat(p0.publicKey), HumanSeat(p1.publicKey), BotSeat(Persona.roster[0]), BotSeat(Persona.roster[1])],
        sealed: sealed,
        house: sealed ? house : null,
        deal: deal,
      );

  test('a sealed table says the revision it is played by, and in its id; one that is not sealed says nothing', () {
    final now = specOf();
    expect(now.deal, dealRevision);
    expect(now.toJson()['deal'], dealRevision);
    expect(TableSpec.parse(jsonDecode(jsonEncode(now.toJson())))?.deal, dealRevision, reason: 'read back as it was written');

    // The id is the hash of what the spec says, the revision with it: two
    // tables that are the same but for it are not the one table.
    final salt = newSalt();
    TableSpec same({int? deal}) => TableSpec(seed: 5, salt: salt, seats: now.seats, sealed: true, house: house, deal: deal);
    expect(same(deal: 1).id, isNot(same().id));

    // An earlier revision says nothing, as every game kept before did.
    final before = specOf(deal: 1);
    expect(before.deal, 1);
    expect(before.toJson().containsKey('deal'), isFalse);
    expect(TableSpec.parse(jsonDecode(jsonEncode(before.toJson())))?.deal, 1);
    expect(TableSpec.parse({...before.toJson(), 'deal': 1}), isNull, reason: 'a spec that says what it need not is not the one its id names');
    expect(TableSpec.kept(id: 'f' * 32, seed: 1, seats: now.seats, sealed: true).deal, 1);

    // Nothing to say of it where nothing is sealed.
    final open = specOf(sealed: false, deal: 2);
    expect(open.deal, 1);
    expect(open.toJson().containsKey('deal'), isFalse);
    expect(TableSpec.parse({...open.toJson(), 'deal': 2}), isNull);
  });

  test('a table is played by this build\'s revision and no other; a verifier reads the earlier ones as well, and no later', () {
    TableRules start(TableSpec s, {bool old = false}) {
      final r = TableRules(tableId: s.id, crypto: crypto, readsOldGames: old);
      r.feed(LogEntry(n: 0, t: 1000000, event: TableEvent.sign(p0, table: s.id, kind: EventKind.start, body: {'spec': s.toJson()})));
      return r;
    }

    final now = specOf();
    final before = specOf(deal: 1);
    final later = specOf(deal: dealRevision + 1);
    expect(start(now).spec, isNotNull);
    expect(start(now, old: true).spec, isNotNull);
    expect(start(before).spec, isNull, reason: 'a table plays none but its own build\'s revision');
    expect(start(before).state, TableState.failed);
    expect(start(later).spec, isNull);
    expect(start(before, old: true).spec, isNotNull, reason: 'a verifier reads a game played before');
    expect(start(later, old: true).spec, isNull, reason: 'and not one it knows nothing of');
    // Where nothing is sealed there is no deal to read.
    final open = specOf(sealed: false);
    expect(TableRules(tableId: open.id)..feed(LogEntry(n: 0, t: 1000000, event: TableEvent.sign(p0, table: open.id, kind: EventKind.start, body: {'spec': open.toJson()}))),
        isA<TableRules>().having((r) => r.spec, 'spec', isNotNull));
  });
}
