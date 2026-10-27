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
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/net/report_error.dart' show noticed;
import 'package:open_hearts/pictures.dart';
import 'package:open_hearts/report.dart';
import 'package:open_hearts/router.dart';
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
    bool strangers = false,
    int seed = 21,
    Transport Function(Transport line)? myLine,
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
          transport: (myLine ?? (line) => line)(net.attach(signers[s].publicKey)),
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
          strangers: strangers,
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
    bool strangers = false,
    Transport Function(Transport line)? myLine,
    ReportSender? report}) async {
  tester.view
    ..physicalSize = const Size(390, 844)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final live =
      LiveHarness(
          crypto: crypto,
          pictures: pictures,
          avatars: avatars,
          target: target,
          rated: rated,
          botSeats: botSeats,
          jurors: jurors,
          workers: workers,
          strangers: strangers,
          myLine: myLine);
  await tester.pumpWidget(MaterialApp(
      theme: buildTheme(), home: LivePage(controller: live.controller, report: report ?? (_) async => throw StateError('no report expected'))));
  await tester.pumpAndSettle();
  return live;
}

/// This device's line as a table's first opens: a socket not open yet
/// sends nothing, hears nothing and is cut off (packages/table,
/// relays.dart), until [open]; and as the network has it after.
class OpeningLine implements Transport {
  OpeningLine(this.line);
  final Transport line;
  bool open = false;

  @override
  bool get cutOff => !open || line.cutOff;
  @override
  void broadcast(Map<String, Object?> message, {bool everywhere = false}) {
    if (open) line.broadcast(message, everywhere: everywhere);
  }

  @override
  late final incoming = line.incoming.where((_) => open);
  @override
  Stream<PublicKey> get disconnected => line.disconnected;
  @override
  List<String> get paths => line.paths;
  @override
  void heard(PublicKey peer, List<String> paths) => line.heard(peer, paths);
  @override
  void reach(Set<PublicKey> peers) => line.reach(peers);
  @override
  void close() => line.close();
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

  // A table's line opens a moment after the table does: in a browser on
  // the rig, a second or so, with the line up all along. Sealed, as
  // every table people play at is, so that its deal waits on the line;
  // and with bots, as most are, whose jury it has not heard yet either.
  for (final bots in [false, true]) {
    testWidgets('a table${bots ? ' with bots' : ''} whose line is still opening says nothing of it, nor of the others, until it has tried as long as a line is given',
        (tester) async {
      late OpeningLine line;
      final live = await pumpLive(tester,
          crypto: await rememberedCrypto(), botSeats: bots ? const {1, 3} : const {}, jurors: bots ? 4 : 0, myLine: (l) => line = OpeningLine(l));
      const down = 'Your connection is down — reconnecting';
      for (var s = 0; s < 10; s++) {
        expect(find.text(down), findsNothing, reason: '$s s in, never up');
        // Nobody heard yet: nothing said of the others, or of a jury —
        // the deal's own note, and that alone.
        expect(find.text(live.controller.dealNote!), findsOneWidget, reason: '$s s in: the deal, all there is to say');
        for (final note in ['Waiting for the others to reconnect', 'Asking the jury', 'Nobody online to draw a jury from — waiting for one', 'Waiting for the jury']) {
          expect(find.text(note), findsNothing, reason: '$s s in: $note');
        }
        await live.advance(tester, 1000);
      }
      expect(live.controller.client.cutOff, isTrue);
      expect(find.text(down), findsOneWidget, reason: 'ten seconds without the line is the line down, as it is once up');

      line.open = true;
      for (var s = 0; s < 5 && find.text(down).evaluate().isNotEmpty; s++) {
        await live.advance(tester, 1000);
      }
      expect(find.text(down), findsNothing, reason: 'up, and the note gone');
      for (var guard = 0; guard < 120 && live.controller.game.phase == engine.Phase.dealing; guard++) {
        await live.advance(tester, 500);
      }
      expect(live.controller.game.phase, engine.Phase.passing, reason: 'and the hand dealt');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a line that has been up says it is down as soon as it is cut off, however soon after the table opened', (tester) async {
    late OpeningLine line;
    final live = await pumpLive(tester, crypto: await rememberedCrypto(), myLine: (l) => line = OpeningLine(l));
    const down = 'Your connection is down — reconnecting';
    await live.advance(tester, 1000);
    line.open = true;
    await live.advance(tester, 1000);
    expect(live.controller.client.cutOff, isFalse);
    expect(find.text(down), findsNothing);

    // Its socket drops, two seconds in: no longer opening, but down.
    line.open = false;
    await live.advance(tester, 1000);
    expect(find.text(down), findsOneWidget, reason: 'down at once, as a socket that drops is');
    line.open = true;
    for (var s = 0; s < 5 && find.text(down).evaluate().isNotEmpty; s++) {
      await live.advance(tester, 1000);
    }
    expect(find.text(down), findsNothing, reason: 'back');
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

  group('leaving a game still going', () {
    /// The table as the front door opens it, on the app's own routes
    /// (router.dart): its way back, and a browser's, are the real ones.
    /// Resolves to the table's page closing, with what it said.
    Future<({GoRouter router, Future<bool?> closed})> openThroughApp(WidgetTester tester, LiveHarness live) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      late BuildContext door;
      final router = appRouter(
        boot: Uri.parse('https://play.openhearts.game/'),
        initialLocation: '/',
        home: (_, _) => Builder(builder: (c) {
          door = c;
          return const SizedBox();
        }),
      );
      await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
      final closed = door.push<bool>('/live', extra: live.controller);
      await tester.pumpAndSettle();
      expect(find.byType(LivePage), findsOneWidget);
      return (router: router, closed: closed);
    }

    /// Past the pass, into the play: a game going on.
    Future<void> intoTheGame(WidgetTester tester, LiveHarness live) async {
      await act(tester, live);
      await live.advance(tester, 2000);
      expect(live.controller.game.phase, engine.Phase.playing);
    }

    Future<void> leaveFromTheMenu(WidgetTester tester) async {
      await tester.tap(find.bySemanticsLabel('Menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave the table'));
      await tester.pumpAndSettle();
    }

    String asked(WidgetTester tester) =>
        tester.widget<Text>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)).at(1)).data!;

    testWidgets('is asked first, saying what it costs: the seat, a rated game, and Play live\'s wait; Stay stays', (tester) async {
      final live = await pumpLive(tester, rated: true, strangers: true);
      await intoTheGame(tester, live);
      await leaveFromTheMenu(tester);
      expect(find.text('Leave the table?'), findsOneWidget);
      expect(
          asked(tester),
          'A bot takes your seat for the rest of the game. '
          'The game is rated, and counts as one you finished last. '
          "Play live won't seat you again for 5 minutes.");
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.text('Leave the table?'), findsNothing);
      expect(live.controller.left, isFalse);
      expect(live.controller.amSeated, isTrue);
      expect(live.controller.leftEarly, isFalse);
      // And the game goes on, with this player in it.
      for (var guard = 0; guard < 40 && !live.controller.awaitingPlay; guard++) {
        await live.advance(tester, 500);
      }
      await act(tester, live);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Leave leaves: early, at a table Play live seated, with other people still playing', (tester) async {
      final live = LiveHarness(rated: true, strangers: true);
      final open = await openThroughApp(tester, live);
      await intoTheGame(tester, live);
      await leaveFromTheMenu(tester);
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(live.controller.left, isTrue);
      expect(live.controller.leftEarly, isTrue);
      expect(find.byType(LivePage), findsNothing, reason: 'back at the door');
      expect(await open.closed, isNull);
      // The leave said, the socket closed a beat later.
      await tester.pump(LiveController.leaveBeat);
    });

    testWidgets('at a friends\' table it says only what becomes of the seat, and is not a game left early', (tester) async {
      final live = LiveHarness();
      await openThroughApp(tester, live);
      await intoTheGame(tester, live);
      await leaveFromTheMenu(tester);
      expect(asked(tester), 'A bot takes your seat for the rest of the game.');
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(live.controller.left, isTrue);
      expect(live.controller.leftEarly, isFalse);
      await tester.pump(LiveController.leaveBeat);
    });

    testWidgets('with nobody else at the table there is no wait to say, and none after', (tester) async {
      final live = LiveHarness(strangers: true, botSeats: {0, 1, 3});
      await openThroughApp(tester, live);
      await intoTheGame(tester, live);
      expect(live.controller.othersSeated, isFalse);
      await leaveFromTheMenu(tester);
      expect(asked(tester), 'A bot takes your seat for the rest of the game.');
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(live.controller.leftEarly, isFalse);
      await tester.pump(LiveController.leaveBeat);
    });

    testWidgets('the wait said is the operator\'s, and none is said where there is none', (tester) async {
      addTearDown(() => RemoteSettings.current = RemoteSettings());
      RemoteSettings.current.adopt(RemoteConfig.parse({'leftEarlyMin': 1}));
      final live = await pumpLive(tester, strangers: true);
      await intoTheGame(tester, live);
      await leaveFromTheMenu(tester);
      expect(asked(tester), "A bot takes your seat for the rest of the game. Play live won't seat you again for a minute.");
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      RemoteSettings.current.adopt(RemoteConfig.parse({'leftEarlyMin': 0}));
      await leaveFromTheMenu(tester);
      expect(asked(tester), 'A bot takes your seat for the rest of the game.');
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
    });

    testWidgets('going back is leaving too, and asked the same; Stay stays at the table', (tester) async {
      final live = LiveHarness(strangers: true);
      await openThroughApp(tester, live);
      await intoTheGame(tester, live);
      // A phone's own Back.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Leave the table?'), findsOneWidget);
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.byType(LivePage), findsOneWidget);
      expect(live.controller.left, isFalse);
      // And again, leaving.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(LivePage), findsNothing);
      expect(live.controller.leftEarly, isTrue);
      await tester.pump(LiveController.leaveBeat);
    });

    testWidgets('a browser\'s Back is asked the same: Stay keeps the table and its address; Leave leaves, and the door is told the table closed', (tester) async {
      final live = LiveHarness(strangers: true);
      final open = await openThroughApp(tester, live);
      var closed = 0;
      live.controller.onClosed = () => closed++;
      await intoTheGame(tester, live);
      // A browser's Back reaches the router as an address to go to, past
      // the page's own Back, as this does.
      open.router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('Leave the table?'), findsOneWidget);
      expect(asked(tester), "A bot takes your seat for the rest of the game. Play live won't seat you again for 5 minutes.");
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.byType(LivePage), findsOneWidget);
      expect(live.controller.left, isFalse);
      expect(open.router.routeInformationProvider.value.uri.path, '/live', reason: 'the address back at the table');
      expect(closed, 0);
      // And again, leaving.
      open.router.go('/');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(LivePage), findsNothing);
      expect(live.controller.left, isTrue, reason: 'said, not left for the table to give up on');
      expect(live.controller.leftEarly, isTrue);
      expect(closed, 1);
      await tester.pump(LiveController.leaveBeat);
    });

    testWidgets('a way out taken while the question shows asks nothing more: the question answers it', (tester) async {
      final live = LiveHarness(strangers: true);
      final open = await openThroughApp(tester, live);
      await intoTheGame(tester, live);
      await leaveFromTheMenu(tester);
      // A browser's Back with the menu's question still open.
      open.router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('Leave the table?'), findsOneWidget, reason: 'one question, not two');
      expect(find.byType(LivePage), findsOneWidget);
      expect(open.router.routeInformationProvider.value.uri.path, '/live');
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.text('Leave the table?'), findsNothing);
      expect(find.byType(LivePage), findsOneWidget);
      expect(live.controller.left, isFalse);
    });

    testWidgets('a game the table has ended is nobody\'s game left early, while the screen still plays its last trick out', (tester) async {
      final live = await pumpLive(tester, target: 1, strangers: true);
      await intoTheGame(tester, live);
      // The table and the screen on one clock, a little at a time, until
      // the table's game is over and the screen's is not yet.
      for (var guard = 0; guard < 4000 && live.controller.client.game.phase != engine.Phase.gameOver; guard++) {
        await act(tester, live);
        await live.tick(tester, 50, step: 50);
      }
      expect(live.controller.client.game.phase, engine.Phase.gameOver);
      expect(live.controller.done, isFalse, reason: 'its last trick still to be shown');
      expect(live.controller.inGame, isTrue, reason: 'so leaving now is still asked');
      expect(live.controller.othersPlaying, isFalse, reason: 'nobody\'s game goes on');
      live.controller.leave();
      expect(live.controller.leftEarly, isFalse);
      // The page gone, and the leave's beat on the socket with it.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(LiveController.leaveBeat);
    });

    testWidgets('a game over asks nothing, and is no game left early', (tester) async {
      final live = LiveHarness(target: 1, strangers: true);
      await openThroughApp(tester, live);
      for (var guard = 0; guard < 400 && !live.controller.gameOverDue; guard++) {
        await act(tester, live);
        await live.advance(tester, 500);
      }
      expect(live.controller.inGame, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Leave the table?'), findsNothing);
      expect(find.byType(LivePage), findsNothing);
      expect(live.controller.leftEarly, isFalse);
    });

    testWidgets('a seat the table gives to a bot is a game left early at a Play live table with people at it, and only there', (tester) async {
      for (final strangers in [true, false]) {
        final live = await pumpLive(tester, strangers: strangers);
        await intoTheGame(tester, live);
        // Say nothing on turn: the others boot this seat.
        for (var guard = 0; guard < 200 && live.controller.amSeated; guard++) {
          await live.advance(tester, 1000);
        }
        expect(live.controller.amSeated, isFalse);
        expect(live.controller.left, isFalse, reason: 'not by its own word');
        expect(live.controller.leftEarly, strangers, reason: strangers ? 'Play live seated it' : 'a friends\' table');
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
