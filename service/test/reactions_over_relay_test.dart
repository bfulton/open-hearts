/// A player's reaction over a real relay (packages/table,
/// reactions.dart): to the others at the table and to whoever is
/// watching it, never back to the one who said it, kept by nobody — and
/// a relay that turns one away is not a relay that refuses the table.
library;

import 'dart:async';

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => installNativeSchnorr());
  late Relay relay;
  setUp(() async {
    relay = Relay();
    await relay.serve();
  });
  tearDown(() => relay.close());

  const table = '0123456789abcdef0123456789abcdef';
  final content = const ReactionSaid(Reaction.nice, hand: 0, turn: 4).encode();

  test('a reaction reaches the other seat and a watcher, not its sayer, and is not kept', () async {
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final w = SchnorrSigner.generate();
    final ta = RelayTransport(relays: [relay.url], signer: a, table: table);
    final tb = RelayTransport(relays: [relay.url], signer: b, table: table);
    final tw = RelayTransport(relays: [relay.url], signer: w, table: table, watchOnly: true);
    await Future.wait([ta.allReady, tb.allReady, tw.allReady]).timeout(const Duration(seconds: 5));
    final heardByA = <HeardReaction>[];
    final sub = ta.reactions.listen(heardByA.add);
    final byB = tb.reactions.first.timeout(const Duration(seconds: 5));
    final byW = tw.reactions.first.timeout(const Duration(seconds: 5));
    ta.sayReaction(content);
    final b1 = await byB;
    final w1 = await byW;
    for (final h in [b1, w1]) {
      expect(h.from, a.publicKey);
      expect(h.content, content);
      expect((DateTime.now().millisecondsSinceEpoch ~/ 1000 - h.createdAt).abs(), lessThan(5));
    }
    expect(b1.id, w1.id, reason: 'one signed event, heard by both');
    // And a screen believes it: Ada is seated, and it is the hand.
    expect(ReactionRules().hear(b1, seated: {a.publicKey: 1}, hand: 0), (seat: 1, reaction: Reaction.nice));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(heardByA, isEmpty);
    expect(relay.stored, 0, reason: 'an ephemeral kind: forwarded and forgotten');
    await sub.cancel();
    ta.close();
    tb.close();
    tw.close();
  });

  test('a relay that turns a reaction away still carries the table: the refusal is the reaction\'s own', () async {
    relay.refuse = (e) => e.kind == TableKinds.react ? 'invalid: not a reaction this relay carries' : null;
    final a = SchnorrSigner.generate();
    final b = SchnorrSigner.generate();
    final ta = RelayTransport(relays: [relay.url], signer: a, table: table);
    final tb = RelayTransport(relays: [relay.url], signer: b, table: table);
    await Future.wait([ta.allReady, tb.allReady]).timeout(const Duration(seconds: 5));
    final refusals = <String?>[];
    final sub = ta.refusals.listen(refusals.add);
    ta.sayReaction(content);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // The table's own next word goes to the same relay, and arrives.
    final heard = tb.watch.first.then((m) => m.content).timeout(const Duration(seconds: 5));
    ta.sayWatch({'n': 1});
    expect(await heard, {'n': 1});
    expect(ta.refusal, isNull);
    expect(refusals, isEmpty, reason: 'nothing said under the felt');
    await sub.cancel();
    ta.close();
    tb.close();
  });
}
