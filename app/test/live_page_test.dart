/// The live table, driven by thumb, with three simulated people around
/// it: the protocol on a virtual clock and a simulated network, the
/// widgets real. The player sits at seat 2, so the table is drawn
/// rotated — the same screen as solo play, from a different chair.
library;

import 'package:deal/deal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' as engine;
import 'package:open_hearts/live/live_page.dart';
import 'package:open_hearts/live_controller.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/table_view.dart' show ClockText, TableView;
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

import 'table_page_test.dart' show fanCards, tapCard;

const _me = 2;

class LiveHarness {
  LiveHarness({DealCrypto? crypto}) {
    final signers = [for (var s = 0; s < engine.seatCount; s++) FakeSigner('seat$s')];
    spec = TableSpec(id: 'widget', seed: 21, seats: [for (final s in signers) HumanSeat(s.publicKey)], sealed: crypto != null);
    for (var s = 0; s < engine.seatCount; s++) {
      if (s == _me) {
        controller = LiveController(
          spec: spec,
          seatNames: const {0: 'Ada', 1: 'Bao', 3: 'Dee'},
          signer: signers[s],
          transport: net.attach(signers[s].publicKey),
          clock: clock,
          crypto: crypto,
        );
      } else {
        final client =
            TableClient(spec: spec, signer: signers[s], transport: net.attach(signers[s].publicKey), clock: clock, crypto: crypto);
        final person = ScriptedHuman(client, net, clock, persona: engine.Persona.westley, thinkMs: 300);
        people[s] = person;
        person.start();
      }
    }
  }

  final clock = VirtualClock();
  late final SimNetwork net = SimNetwork(clock, seed: 3);
  late final TableSpec spec;
  late final LiveController controller;
  final Map<int, ScriptedHuman> people = {};

  /// Lets [ms] of virtual time pass at the table and on the screen
  /// alike — the view paces itself by timers of its own, and a screen
  /// that fell behind the table would be booted from it — and the
  /// widgets catch up.
  Future<void> advance(WidgetTester tester, int ms) async {
    clock.advance(ms);
    await tester.pump(Duration(milliseconds: ms));
    await tester.pumpAndSettle();
  }
}

Future<LiveHarness> pumpLive(WidgetTester tester, {DealCrypto? crypto}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final live = LiveHarness(crypto: crypto);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: LivePage(controller: live.controller)));
  await tester.pumpAndSettle();
  return live;
}

/// Plays for the thumb: passes anything, plays the first legal card.
Future<void> act(WidgetTester tester, LiveHarness live) async {
  if (live.controller.awaitingPass) {
    final hand = fanCards(tester);
    for (var i = 0; i < 3; i++) {
      await tapCard(tester, hand[i].card);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Pass'));
    await tester.pumpAndSettle();
  } else if (live.controller.awaitingPlay) {
    final playable = fanCards(tester).where((c) => !c.dimmed).toList();
    if (playable.isNotEmpty) await tapCard(tester, playable.first.card);
  }
}

void main() {
  testWidgets('sits at seat 2, passes, plays, and sees the others by name around the table', (tester) async {
    final live = await pumpLive(tester);
    expect(live.controller.mySeat, _me);
    expect(find.text('You'), findsWidgets);
    expect(find.text('Ada'), findsWidgets);
    expect(find.text('Dee'), findsWidgets);
    expect(find.textContaining('4 of 4 here'), findsOneWidget);
    expect(find.text('Pass'), findsOneWidget);

    // Pass, and let the others pass; the play begins.
    await act(tester, live);
    await live.advance(tester, 2000);
    expect(live.controller.game.phase, engine.Phase.playing);

    // Play the hand out: my turns by thumb, theirs by the clock.
    for (var guard = 0; guard < 400 && live.controller.game.handNumber == 0; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(live.controller.game.handNumber, 1, reason: 'the first hand finished');
    // The score sheet of the hand just finished shows, and dismisses.
    expect(find.text('On with it'), findsOneWidget);
    await tester.tap(find.text('On with it'));
    await tester.pumpAndSettle();
    expect(find.text('On with it'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a person who leaves becomes a bot; a person who goes quiet on turn can be booted', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);

    // Ada, at seat 0, leaves.
    live.people[0]!.depart(Exit.leave);
    await live.advance(tester, 500);
    expect(live.controller.personaAt(0), isNotNull, reason: 'a bot holds seat 0');
    expect(find.textContaining('3 of 4 here'), findsOneWidget);
    expect(find.text(live.controller.names[0]), findsWidgets, reason: 'the bot is named on the table');

    // Bao, at seat 1, goes quiet. When it is Bao's turn the clock runs,
    // and at fifteen seconds the Boot button appears.
    live.people[1]!.depart(Exit.idle);
    for (var guard = 0; guard < 200 && !live.controller.canBoot(1); guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.canBoot(1), isTrue);
    expect(find.text('Boot Bao'), findsOneWidget);
    await tester.tap(find.text('Boot Bao'));
    await live.advance(tester, 3000); // Dee agrees on her own clock
    expect(live.controller.personaAt(1), isNotNull, reason: 'a bot holds seat 1');
    expect(find.textContaining('2 of 4 here'), findsOneWidget);
    expect(live.controller.tableState, TableState.playing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a seat the others boot sees no table, only that a bot took it', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);
    expect(live.controller.game.phase, engine.Phase.playing);
    // Say nothing on turn: the others' clocks on this seat run out,
    // they boot it, and a bot has the seat.
    for (var guard = 0; guard < 200 && live.controller.amSeated; guard++) {
      await live.advance(tester, 1000);
    }
    expect(live.controller.amSeated, isFalse, reason: 'the others booted this seat');
    expect(find.text('A bot took your seat'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.byType(TableView), findsNothing, reason: 'no table to watch');
    expect(find.bySemanticsLabel('Menu'), findsNothing);
    // And it stays that way as the table plays on.
    await live.advance(tester, 5000);
    expect(find.byType(TableView), findsNothing);
    // And no ghost underneath: the shown game never hands this
    // player's own seat to a bot, so nothing plays their cards while
    // they are looking at the notice.
    expect(live.controller.personaAt(_me), isNull, reason: 'no bot on my own seat');
    final mine = live.controller.game.knowsHand(_me) ? live.controller.game.handOf(_me).length : null;
    await live.advance(tester, 20000);
    expect(live.controller.personaAt(_me), isNull, reason: 'still no bot on my own seat');
    if (mine != null) {
      expect(live.controller.game.handOf(_me).length, mine, reason: 'not one of my cards was played for me');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow seat\'s clock shows on its badge once its grace is spent, and yours on your line', (tester) async {
    final live = await pumpLive(tester);
    // Ada takes fourteen seconds over every card; her pass was quick.
    live.people[0]!.thinkMs = 14000;
    await act(tester, live);
    await live.advance(tester, 2000);
    expect(live.controller.game.phase, engine.Phase.playing);
    expect(find.byType(ClockText), findsNothing, reason: 'nothing on the felt while everyone is within their grace');

    // Up to Ada's turn, then past her six seconds of grace.
    for (var guard = 0; guard < 120 && live.controller.clockMs(0) == null; guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.clockMs(0), isNotNull, reason: 'Ada is on turn and past her grace');
    expect(find.bySemanticsLabel(RegExp(r'^Ada: .*, on turn, \d+ s on the clock$')), findsOneWidget);
    expect(find.byType(ClockText), findsOneWidget);
    expect(find.text('Boot Ada'), findsNothing, reason: 'the bank is not spent');
    expect(find.textContaining(' has '), findsNothing, reason: 'the old note is gone');

    // Your own: dawdle on your turn past the grace, and the score line says so.
    for (var guard = 0; guard < 120 && !live.controller.awaitingPlay; guard++) {
      if (live.controller.awaitingPass) await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.awaitingPlay, isTrue);
    expect(live.controller.clockMs(_me), isNull);
    await live.advance(tester, 7000);
    expect(live.controller.clockMs(_me), isNotNull);
    expect(find.bySemanticsLabel(RegExp(r'^You: .*, \d+ s on the clock$')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('at a sealed table the deal shows, the others\' cards are backs, and the hand plays out', (tester) async {
    final crypto = await DealCrypto.load();
    final live = await pumpLive(tester, crypto: crypto);
    // The deal runs on the virtual clock: keys wait up to ten seconds
    // for a jury there is none of here, then the shuffles and the
    // rest. Somewhere along it the rail says so.
    var sawDealing = false;
    for (var guard = 0; guard < 60 && live.controller.game.phase == engine.Phase.dealing; guard++) {
      await live.advance(tester, 500);
      if (find.textContaining('Shuffling').evaluate().isNotEmpty || find.textContaining('Dealing').evaluate().isNotEmpty) sawDealing = true;
    }
    expect(sawDealing, isTrue, reason: 'the rail showed the deal');
    expect(live.controller.game.phase, engine.Phase.passing);
    expect(live.controller.game.knowsHand(_me), isTrue);
    for (var s = 0; s < engine.seatCount; s++) {
      if (s == _me) continue;
      expect(live.controller.game.knowsHand(s), isFalse, reason: 'seat $s\'s cards are not mine to see');
      expect(live.controller.game.handSizeOf(s), 13);
    }
    expect(find.text('Pass'), findsOneWidget);
    await act(tester, live);
    await live.advance(tester, 2000);
    expect(live.controller.game.phase, engine.Phase.playing);
    // Ada leaves after a few tricks: her hand is opened from the
    // pieces the others hold, her bot plays it at the table at once,
    // and the shown game — behind, at its own pace — shows it right.
    var left = false;
    for (var guard = 0; guard < 400 && live.controller.game.handNumber == 0; guard++) {
      if (!left && live.controller.client.game.tricksPlayed >= 3) {
        live.people[0]!.depart(Exit.leave);
        left = true;
      }
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(left, isTrue);
    expect(live.controller.personaAt(0), isNotNull, reason: 'a bot holds seat 0');
    expect(live.controller.game.handNumber, 1, reason: 'the first hand finished');
    final v = live.controller.verification();
    expect(v.ok, isTrue, reason: v.reason);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
