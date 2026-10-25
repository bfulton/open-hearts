/// The live table, driven by thumb, with three simulated people around
/// it: the protocol on a virtual clock and a simulated network, the
/// widgets real. The player sits at seat 2, so the table is drawn
/// rotated — the same screen as solo play, from a different chair.
/// The sealed tables and the jury's seats are live_page_sealed_test.dart's,
/// on the harness here, so the two run side by side.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/live/live_controller.dart';
import 'package:open_hearts/live/live_page.dart';
import 'package:open_hearts/net/report_error.dart' show noticed;
import 'package:open_hearts/pictures.dart';
import 'package:open_hearts/report.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/player_icon.dart' show BotMark;
import 'package:open_hearts/ui/table_view.dart' show ClockText, TableView;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';
import 'package:table_sim/table_sim.dart';

import 'drawn.dart';
import 'table_page_test.dart' show fanCards, tapCard;

const _me = 2;

/// The seat the harness sits this device at, for the files that drive it.
const harnessSeat = _me;

class LiveHarness {
  LiveHarness({
    DealCrypto? crypto,
    this.pictures,
    Map<int, Avatar> avatars = const {},
    int target = engine.gameOverScore,
    bool rated = false,
    Set<int> botSeats = const {},
    int jurors = 0,
    bool workers = false,
    bool canPlayAgain = false,
    int seed = 21,
  }) {
    // Each device's deal work in a worker of its own, taking a
    // browser's time over each job, as the app's does.
    SimDealWorker? worker() => workers && crypto != null ? SimDealWorker(crypto, clock) : null;
    final signers = [for (var s = 0; s < engine.seatCount; s++) FakeSigner('seat$s')];
    keys = [for (final s in signers) s.publicKey];
    spec = TableSpec(
        id: 'widget',
        seed: seed,
        seats: [
          for (var s = 0; s < engine.seatCount; s++)
            if (botSeats.contains(s)) BotSeat(engine.Persona.roster[s % engine.Persona.roster.length]) else HumanSeat(signers[s].publicKey),
        ],
        sealed: crypto != null,
        rated: rated,
        target: target);
    // Jurors to draw from, for the seats a bot sits in: at a sealed
    // table those are a juror's to hold and play, and their hands are
    // not this screen's to see (docs/explanation/live-play.md).
    if (jurors > 0) {
      final p = presence = SimPresence(net, clock);
      for (var j = 0; j < jurors; j++) {
        final juror = SimJuror(FakeSigner('juror$j'), net, clock, crypto: crypto, dealWorker: worker());
        this.jurors.add(juror);
        p.register(juror);
      }
      p.start();
    }
    for (var s = 0; s < engine.seatCount; s++) {
      if (botSeats.contains(s)) continue;
      if (s == _me) {
        controller = LiveController(
          spec: spec,
          seatNames: const {0: 'Ada', 1: 'Bao', 3: 'Dee'},
          seatAvatars: avatars,
          pictures: pictures,
          signer: signers[s],
          transport: net.attach(signers[s].publicKey),
          clock: clock,
          crypto: crypto,
          dealWorker: myWorker = worker(),
          presence: presence,
          // A rated table reads its ratings from this device's own
          // ledger and folds the finished game into it, as the front
          // door does off the relays (net/standing.dart).
          ratingOf: rated ? ledger.of : null,
          onResult: rated ? ledger.apply : null,
          canPlayAgain: canPlayAgain,
          reactions: reactions.lane(signers[s].publicKey),
          reactionClock: reactions.nowMs,
        );
      } else {
        final client = TableClient(
            spec: spec,
            signer: signers[s],
            transport: net.attach(signers[s].publicKey),
            clock: clock,
            crypto: crypto,
            dealWorker: worker(),
            presence: presence);
        final person = ScriptedHuman(client, net, clock, persona: engine.Persona.westley, thinkMs: 300);
        people[s] = person;
        person.start();
      }
    }
  }

  /// What this device does with the others' pictures, where a test
  /// cares.
  final Pictures? pictures;

  /// This device's deal worker, when the harness has them.
  SimDealWorker? myWorker;

  /// The ratings this device knows, at a rated table: empty, so
  /// everyone starts fresh.
  final ledger = Ledger();

  final clock = VirtualClock();
  late final SimNetwork net = SimNetwork(clock, seed: 3);

  /// Each seat's device's key, by seat.
  late final List<PublicKey> keys;

  /// The players' reactions (packages/table, reactions.dart): what
  /// anyone at the table says, this device hears. On the screen's own
  /// clock, the test's, which is the one a bubble goes by.
  final reactions = ReactionHub(nowMs: () => TestWidgetsFlutterBinding.instance.clock.now().millisecondsSinceEpoch);

  /// [seat]'s player says [reaction], at this hand, as their device
  /// would.
  void reactFrom(int seat, Reaction reaction) =>
      reactions.sayAs(keys[seat], ReactionSaid(reaction, hand: controller.client.game.handNumber, turn: 0).encode());

  /// Who is online to be drawn as a juror, and the jurors themselves.
  SimPresence? presence;
  final List<SimJuror> jurors = [];
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

  /// The table and the screen on one clock, in small steps. [advance]
  /// settles the widgets with the table held still, which lets a screen
  /// catch up on a table that has stopped to wait for it; here neither
  /// waits for the other, as at a real table.
  Future<void> tick(WidgetTester tester, int ms, {int step = 100}) async {
    for (var t = 0; t < ms; t += step) {
      clock.advance(step);
      await tester.pump(Duration(milliseconds: step));
    }
  }
}

Future<LiveHarness> pumpLive(WidgetTester tester,
    {DealCrypto? crypto,
    Pictures? pictures,
    Map<int, Avatar> avatars = const {},
    int target = engine.gameOverScore,
    bool rated = false,
    Set<int> botSeats = const {},
    int jurors = 0,
    bool workers = false,
    ReportSender? report}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final live =
      LiveHarness(
          crypto: crypto, pictures: pictures, avatars: avatars, target: target, rated: rated, botSeats: botSeats, jurors: jurors, workers: workers);
  await tester.pumpWidget(MaterialApp(
      theme: buildTheme(), home: LivePage(controller: live.controller, report: report ?? (_) async => throw StateError('no report expected'))));
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

  testWidgets('a rated game ends by saying what it did to your rating', (tester) async {
    // A game to a point is over at the end of the first hand, which is
    // the whole of what the sheet needs.
    final live = await pumpLive(tester, target: 1, rated: true);
    for (var guard = 0; guard < 400 && !live.controller.gameOverDue; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(find.text('Home'), findsOneWidget, reason: 'the game is over and its sheet is up');
    final change = live.controller.ratingChange!;
    expect(change.before.shown, 1500, reason: 'nothing in this device\'s ledger before the game');
    expect(change.after.shown, isNot(1500), reason: 'and the game moved it');
    final moved = change.after.shown - change.before.shown;
    expect(find.text('Rating 1500? → ${change.after.shown}?'), findsOneWidget);
    expect(find.text(moved > 0 ? '+$moved' : '$moved'), findsOneWidget);
  });

  // Opened as the front door opens it, by the router: what the sheet
  // closes with is what the door is told.
  Future<bool?> endThrough(WidgetTester tester, String tap) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final live = LiveHarness(target: 1, canPlayAgain: true);
    late BuildContext door;
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => Builder(builder: (c) {
        door = c;
        return const SizedBox();
      })),
      GoRoute(path: '/live', builder: (_, state) => LivePage(controller: state.extra! as LiveController)),
    ]);
    await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
    bool? told;
    var closed = false;
    unawaited(door.push<bool>('/live', extra: live.controller).then((v) {
      told = v;
      closed = true;
    }));
    await tester.pumpAndSettle();
    for (var guard = 0; guard < 400 && !live.controller.gameOverDue; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(find.text('Play again'), findsOneWidget, reason: 'the game is over, and another can begin the same way');
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('See the whole game'), findsOneWidget);
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
    expect(closed, isTrue, reason: 'the table is left either way');
    return told;
  }

  testWidgets('Play again leaves the table telling the front door to begin another', (tester) async {
    expect(await endThrough(tester, 'Play again'), isTrue);
  });

  testWidgets('Home beside it leaves the table for the front door, and nothing more', (tester) async {
    expect(await endThrough(tester, 'Home'), isFalse);
  });

  testWidgets('an unrated game says nothing about ratings', (tester) async {
    final live = await pumpLive(tester, target: 1);
    for (var guard = 0; guard < 400 && !live.controller.gameOverDue; guard++) {
      await act(tester, live);
      await live.advance(tester, 500);
    }
    expect(find.text('Home'), findsOneWidget, reason: 'the game is over and its sheet is up');
    expect(live.controller.ratingChange, isNull);
    expect(find.textContaining('Rating'), findsNothing, reason: 'nothing was at stake, so there is nothing to report');
  });

  testWidgets('a person who leaves becomes a bot; a person who goes quiet on turn can be booted', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);
    expect(find.byType(BotMark), findsNothing, reason: 'four people, no bot');

    // Ada, at seat 0, leaves.
    live.people[0]!.depart(Exit.leave);
    await live.advance(tester, 500);
    expect(live.controller.personaAt(0), isNotNull, reason: 'a bot holds seat 0');
    expect(find.textContaining('3 of 4 here'), findsOneWidget);
    expect(find.text(live.controller.names[0]), findsWidgets, reason: 'the bot is named on the table');
    // And it is told from the people still there, to the eye and the ear.
    expect(find.byIcon(Icons.smart_toy).hitTestable(), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^${live.controller.names[0]}, a bot: ')), findsOneWidget);

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

  testWidgets('a device no relay will take neither offers a Boot nor settles one', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);
    live.people[0]!.depart(Exit.leave);
    await live.advance(tester, 500);

    // This device's own events are going nowhere: every relay refuses
    // them. What looks from here like Bao's silence may be this
    // device's own deafness, and a claim it made would not reach the
    // table anyway. So while it is cut off it neither offers the Boot
    // nor countersigns the one Dee raises, and Bao keeps the seat.
    live.controller.client.writesRefused = true;
    live.people[1]!.depart(Exit.idle);
    for (var guard = 0; guard < 80; guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.canBoot(1), isFalse, reason: 'cut off, so not this device to judge');
    expect(find.text('Boot Bao'), findsNothing, reason: 'and no button to press');
    expect(live.controller.personaAt(1), isNull, reason: 'and nothing settles Bao out of the seat');

    // A relay takes its events again: it judges again, and the seat
    // settles.
    live.controller.client.writesRefused = false;
    for (var guard = 0; guard < 30 && live.controller.personaAt(1) == null; guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.personaAt(1), isNotNull, reason: 'a bot holds seat 1');
    expect(tester.takeException(), isNull);
  });

  // A line whose way in has stalled while its way out still carries, as
  // a plane's satellite link did: the table is still there, and this
  // device is the one not hearing it (packages/table, transport.dart).
  testWidgets('a device that hears nothing back says its own connection is down, and no more once it is back', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);
    const down = 'Your connection is down — reconnecting';
    expect(find.text(down), findsNothing);
    final lines = <(String, Map<String, String>)>[];
    noticed = (message, attributes) => lines.add((message, attributes));
    addTearDown(() => noticed = null);

    live.net.deafen(live.keys[harnessSeat]);
    for (var s = 0; s < 15 && find.text(down).evaluate().isEmpty; s++) {
      await live.advance(tester, 1000);
    }
    expect(live.controller.client.cutOff, isTrue);
    expect(find.text(down), findsOneWidget, reason: 'said under the felt, over whatever the table seems to wait on');
    expect(lines, isEmpty, reason: 'a minute or two down is not told of');

    live.net.hearAgain(live.keys[harnessSeat]);
    for (var s = 0; s < 15 && find.text(down).evaluate().isNotEmpty; s++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(find.text(down), findsNothing, reason: 'back, and the note gone');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line down for two minutes at a live table is told of, once, with what the device saw', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);
    final lines = <(String, Map<String, String>)>[];
    noticed = (message, attributes) => lines.add((message, attributes));
    addTearDown(() => noticed = null);

    live.net.deafen(live.keys[harnessSeat]);
    for (var s = 0; s < 200 && lines.isEmpty; s++) {
      await live.advance(tester, 1000);
    }
    expect(lines, hasLength(1), reason: 'told of once it had been down two minutes');
    final (message, attributes) = lines.single;
    expect(message, startsWith('live: line down 1'));
    expect(attributes['table'], 'widget');
    expect(attributes['seen'], contains('cut off now'));
    expect(attributes['line'], isNotNull);
    expect(attributes['build'], isNotNull);
    for (final k in live.keys) {
      expect('$attributes', isNot(contains(k.substring(0, 6))), reason: 'no key in it');
    }
    for (var s = 0; s < 60; s++) {
      await live.advance(tester, 1000);
    }
    expect(lines, hasLength(1), reason: 'and once only');
    live.net.hearAgain(live.keys[harnessSeat]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a game lost with the line up is told of, once, as lost and not as a line down', (tester) async {
    final live = await pumpLive(tester);
    await act(tester, live);
    await live.advance(tester, 2000);
    final lines = <(String, Map<String, String>)>[];
    noticed = (message, attributes) => lines.add((message, attributes));
    addTearDown(() => noticed = null);

    // Everyone else gone at once, this device's own line fine: the
    // last person at the table, who ends the game once the rest have
    // been silent as long as a person is given.
    for (final s in [0, 1, 3]) {
      live.net.goOffline(live.keys[s]);
    }
    for (var s = 0; s < 300 && live.controller.client.failure == null; s++) {
      await live.advance(tester, 1000);
    }
    expect(live.controller.client.failure, isNotNull, reason: live.controller.client.describe());
    await live.advance(tester, 1000);
    expect(lines, hasLength(1));
    final (message, attributes) = lines.single;
    expect(message, 'live: game lost: juror quorum lost');
    expect(attributes['seen'], contains('line up, cut off 0 times'));
    for (var s = 0; s < 10; s++) {
      await live.advance(tester, 1000);
    }
    expect(lines, hasLength(1), reason: 'once');
  });

  testWidgets('holding a badge hides that player\'s picture on this device, and nothing else', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picture = Uint8List.fromList(List.generate(64, (i) => i));
    final pictures = await Pictures.load();
    final live = await pumpLive(tester, pictures: pictures, avatars: {1: Avatar(picture: picture)});
    await act(tester, live);
    await live.advance(tester, 1000);

    Avatar bao() => live.controller.avatarOf(1);
    expect(bao().picture, isNotNull, reason: 'Bao chose a picture and nothing is against it');

    // Hold Bao's badge: what this device does with their picture.
    await tester.longPress(find.bySemanticsLabel(RegExp('^Bao: ')));
    await tester.pumpAndSettle();
    expect(find.text("Hide Bao's picture"), findsOneWidget);
    await tester.tap(find.text("Hide Bao's picture"));
    await tester.pumpAndSettle();
    expect(bao().picture, isNull, reason: 'the picture is off this device\'s table');
    expect(pictures.isHidden((live.spec.seats[1] as HumanSeat).key), isTrue);
    expect(find.text('Bao'), findsWidgets, reason: 'their name and their score stay');

    // And it is the viewer's own decision, so it is theirs to take back.
    await tester.longPress(find.bySemanticsLabel(RegExp('^Bao: ')));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Show Bao's picture"));
    await tester.pumpAndSettle();
    expect(bao().picture, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holding a badge reports that player: their picture, name or something else, with a note', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picture = Uint8List.fromList(List.generate(64, (i) => i));
    final reports = <Report>[];
    var answer = ReportSent.sent;
    final live = await pumpLive(tester, pictures: await Pictures.load(), avatars: {1: Avatar(picture: picture)}, report: (r) async {
      reports.add(r);
      return answer;
    });
    await act(tester, live);
    await live.advance(tester, 1000);

    await tester.longPress(find.bySemanticsLabel(RegExp('^Bao: ')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report Bao'));
    await tester.pumpAndSettle();
    expect(find.text('Their picture'), findsOneWidget);
    final send = find.widgetWithText(FilledButton, 'Send');
    expect(tester.widget<FilledButton>(send).onPressed, isNull, reason: 'nothing chosen, nothing to send');
    await tester.tap(find.text('Their picture'));
    await tester.enterText(find.byType(TextField), '  not a face  ');
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(reports, hasLength(1));
    final r = reports.single;
    expect(r.about, (live.spec.seats[1] as HumanSeat).account);
    expect(r.what, ReportWhat.picture);
    expect(r.picture, sha256Hex(picture), reason: 'the picture as this device shows it, as the service names it');
    expect(r.name, 'Bao');
    expect(r.table, live.spec.id);
    expect(r.note, 'not a face');
    expect(find.text('Report sent. Thank you.'), findsOneWidget);

    // Dee chose no picture: their name or something else, and said so
    // when it does not go.
    answer = ReportSent.failed;
    await tester.longPress(find.bySemanticsLabel(RegExp('^Dee: ')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Dee's picture"), findsNothing);
    await tester.tap(find.text('Report Dee'));
    await tester.pumpAndSettle();
    expect(find.text('Their picture'), findsNothing);
    await tester.tap(find.text('Their name'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(reports.last.what, ReportWhat.name);
    expect(reports.last.picture, isNull);
    expect(find.textContaining("The report didn't go."), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holding a badge blocks that player on this device: no name, no picture; a report still says who; and unblocks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picture = Uint8List.fromList(List.generate(64, (i) => i));
    final pictures = await Pictures.load();
    final reports = <Report>[];
    final live = await pumpLive(tester, pictures: pictures, avatars: {1: Avatar(picture: picture)}, report: (r) async {
      reports.add(r);
      return ReportSent.sent;
    });
    await act(tester, live);
    await live.advance(tester, 1000);
    final bao = (live.spec.seats[1] as HumanSeat).account;

    await tester.longPress(find.bySemanticsLabel(RegExp('^Bao: ')));
    await tester.pumpAndSettle();
    expect(find.text("On this device only: you won't see their name, picture or reactions. They aren't told."), findsOneWidget);
    await tester.tap(find.text('Block Bao'));
    await tester.pumpAndSettle();
    expect(pictures.isBlocked(bao), isTrue);
    expect(live.controller.avatarOf(1).picture, isNull);
    expect(find.textContaining('Bao'), findsNothing, reason: 'their name nowhere on the table');
    expect(find.textContaining('Blocked player'), findsWidgets);

    // Held again: no picture to choose about, and no name; a report
    // still tells the operator who.
    await tester.longPress(find.bySemanticsLabel(RegExp('^Blocked player: ')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bao'), findsNothing);
    expect(find.text('Unblock'), findsOneWidget);
    await tester.tap(find.text('Report Blocked player'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bao'), findsNothing);
    await tester.tap(find.text('Their name'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(reports.single.name, 'Bao');
    expect(reports.single.about, bao);

    await tester.longPress(find.bySemanticsLabel(RegExp('^Blocked player: ')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(pictures.isBlocked(bao), isFalse);
    expect(find.text('Bao'), findsWidgets);
    expect(live.controller.avatarOf(1).picture, isNotNull);
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
    expect(drawn(find.byType(ClockText)), findsNothing, reason: 'nothing on the felt while everyone is within their grace');

    // Up to Ada's turn, then past her six seconds of grace.
    for (var guard = 0; guard < 120 && live.controller.clockMs(0) == null; guard++) {
      await act(tester, live);
      await live.advance(tester, 1000);
    }
    expect(live.controller.clockMs(0), isNotNull, reason: 'Ada is on turn and past her grace');
    expect(find.bySemanticsLabel(RegExp(r'^Ada: .*, on turn, \d+ s on the clock, (on your left|across from you|on your right)$')), findsOneWidget);
    expect(drawn(find.byType(ClockText)), findsOneWidget);
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
}
