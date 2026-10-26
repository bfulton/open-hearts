/// A heartbeat by every path, often enough for the silence it keeps at
/// bay (client.dart, `_heartbeat`): a peer that cannot read the relay
/// a device writes to still hears it three times inside the silence
/// that would see it booted — a person's, at a seat; a juror's, for a
/// juror — and a seat at a table that gives a longer silence floods no
/// more often than that silence asks.
///
/// The table writes to `ra`, the first relay every seat reads. The
/// listener reads only `rb`, which nothing reaches but what goes by
/// every path, or what is written before anyone has said what it
/// reads.
library;

import 'dart:math';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';
import 'package:test/test.dart';

/// When [listener] heard each of [authors]' [kind] — a seat's
/// heartbeat or a juror's serve — on the table's clock.
Map<PublicKey, List<int>> heardOf(SimTable t, SimTransport listener, Iterable<PublicKey> authors, String kind) {
  final at = {for (final a in authors) a: <int>[]};
  listener.incoming.listen((m) {
    final author = m.message['author'];
    if (m.from == author && m.message['kind'] == kind) at[author]?.add(t.clock.nowMs);
  });
  return at;
}

/// The longest wait between two of [at] in [fromMs] to [toMs].
int longestGap(List<int> at, {required int fromMs, required int toMs}) {
  final within = [
    for (final ms in at)
      if (ms >= fromMs && ms <= toMs) ms,
  ];
  expect(within.length, greaterThan(2), reason: 'heard at all: $at');
  return [for (var i = 1; i < within.length; i++) within[i] - within[i - 1]].reduce(max);
}

/// A network's latency, and a timer's, between two sends a beat apart.
const slackMs = 1000;

/// From when the table has said what it reads: before that, a write
/// goes everywhere ([floodWrite]).
const settledMs = 15000;

/// A device on [t]'s network that reads `rb` and nothing else.
SimTransport listenerOn(SimTable t) {
  t.net.relays = const ['ra', 'rb'];
  final listener = t.net.attach('listener');
  t.net.setReach('listener', {'rb'});
  return listener;
}

/// Plays [t] to its end; when that was.
int playOut(SimTable t) {
  expect(t.clock.runUntil(() => t.clients.first.done, limitMs: 20 * 60 * 1000), isTrue, reason: 'the game ended');
  return t.clock.nowMs;
}

void main() {
  // A game to a hundred: long enough to hear a seat by every path
  // several times over at either pace.
  test('a seat is heard by every path three times inside the half minute it may be silent', () {
    final t = SimTable(humans: 2, seed: 5, target: 100);
    final listener = listenerOn(t);
    final a = t.signers[0].publicKey;
    final at = heardOf(t, listener, [a], 'heartbeat')[a]!;
    t.start();
    final end = playOut(t);
    expect(longestGap(at, fromMs: settledMs, toMs: end), lessThanOrEqualTo(TableTiming.standard.silenceMs ~/ 3 + slackMs));
    t.stop();
  });

  test('at a table that gives two minutes, a seat floods a quarter as often, and is still heard three times in them', () {
    final t = SimTable(humans: 2, seed: 5, target: 100, timing: TableTiming.unsaid);
    final listener = listenerOn(t);
    final a = t.signers[0].publicKey;
    final at = heardOf(t, listener, [a], 'heartbeat')[a]!;
    t.start();
    final end = playOut(t);
    expect(longestGap(at, fromMs: settledMs, toMs: end), lessThanOrEqualTo(TableTiming.unsaid.silenceMs ~/ 3 + slackMs));
    final sent = t.clients.first.heartbeatsSent;
    // One in eight by every path, and the first few, written before a
    // peer had said what it reads.
    expect(at.length, lessThanOrEqualTo(sent ~/ 8 + 2), reason: '${at.length} of $sent by every path');
    t.stop();
  });

  group('sealed, with a jury', () {
    late DealCrypto crypto;
    setUpAll(() async => crypto = await rememberedCrypto());

    // A juror's own half minute, at a table that gives a person two;
    // and the ten seconds an operator may give a juror, too short for
    // three serves, where every one goes.
    for (final (name, timing) in [
      ('three times inside its own half minute, at a table that gives a person two', TableTiming.unsaid),
      ('at every serve, where three do not fit inside its ten seconds', const TableTiming(jurorSilenceMs: 10000)),
    ]) {
      test('a juror is heard by every path $name', () {
        final t = SimTable(humans: 2, seed: 3, crypto: crypto, jurors: jurySize + 4, timing: timing);
        final listener = listenerOn(t);
        final serves = heardOf(t, listener, [for (final j in t.jurors) j.signer.publicKey], 'serve');
        t.start();
        expect(
          t.clock.runUntil(() => t.clients.first.game.phase == Phase.playing, limitMs: 5 * 60 * 1000),
          isTrue,
          reason: 'the hand was dealt',
        );
        final from = t.clock.nowMs;
        t.clock.runUntil(() => t.clients.first.done, limitMs: 2 * 60 * 1000);
        final to = t.clock.nowMs;
        final summoned = [
          for (final j in t.jurors)
            if (j.client != null) j.signer.publicKey,
        ];
        expect(summoned, isNotEmpty);
        final apart = max(timing.jurorSilenceMs ~/ 3, t.clients.first.heartbeatMs);
        for (final k in summoned) {
          expect(
            longestGap(serves[k]!, fromMs: from, toMs: to),
            lessThanOrEqualTo(apart + slackMs),
            reason: 'juror ${k.substring(0, 6)}',
          );
        }
        t.stop();
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  });
}
