/// The live table, driven by thumb, with three simulated people around
/// it: the protocol on a virtual clock and a simulated network, the
/// widgets real. The player sits at seat 2, so the table is drawn
/// rotated — the same screen as solo play, from a different chair.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:engine/engine.dart' as engine;
import 'package:open_hearts/live/live_page.dart';
import 'package:open_hearts/live_controller.dart';
import 'package:open_hearts/theme.dart';
import 'package:table/src/sim/sim.dart';
import 'package:table/table.dart';

import 'table_page_test.dart' show fanCards, tapCard;

const _me = 2;

class LiveHarness {
  LiveHarness() {
    final signers = [for (var s = 0; s < engine.seatCount; s++) FakeSigner('seat$s')];
    spec = TableSpec(id: 'widget', seed: 21, seats: [for (final s in signers) HumanSeat(s.publicKey)]);
    for (var s = 0; s < engine.seatCount; s++) {
      if (s == _me) {
        controller = LiveController(
          spec: spec,
          seatNames: const {0: 'Ada', 1: 'Bao', 3: 'Dee'},
          signer: signers[s],
          transport: net.attach(signers[s].publicKey),
          clock: clock,
        );
      } else {
        final client = TableClient(spec: spec, signer: signers[s], transport: net.attach(signers[s].publicKey), clock: clock);
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

Future<LiveHarness> pumpLive(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final live = LiveHarness();
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
}
