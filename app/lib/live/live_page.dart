/// A live table: the same screen as solo play, driven by the protocol.
/// What is different is on the felt and its line — who is connected,
/// the boot clock on a seat that is holding everyone up, a pause and
/// why — and what leaving means: a bot takes the seat.
library;

import 'package:flutter/material.dart';
import 'package:engine/engine.dart' as engine;
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import '../about_page.dart';
import '../live_controller.dart';
import '../table_model.dart' show TableModelHand;
import '../table_page.dart' show ActionBar;
import '../theme.dart';
import '../ui/hand_fan.dart';
import '../ui/header.dart';
import '../ui/overlays.dart';
import '../ui/scoreboard.dart';
import '../ui/table_layout.dart';
import '../ui/table_view.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.controller});

  final LiveController controller;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  LiveController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  void _tapCard(engine.Card card) {
    if (_c.awaitingPass) return _c.toggleSelected(card);
    if (!_c.awaitingPlay) return;
    final refusal = _c.playCard(card);
    if (refusal != null) _say(refusal);
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        duration: const Duration(milliseconds: 1600),
        width: 260,
      ));
  }

  Future<void> _leave() async {
    if (_c.amSeated && !_c.done) {
      _c.leave();
      // Let the leave reach the wire before the transport goes.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// With `?e2e` in the address, the client's own account of the table
  /// (participants, open races, who was heard when) sits in the
  /// accessibility tree, invisible: for a test or a tool driving the
  /// app, and for anyone reading a stuck table.
  Widget _debugState() {
    if (!Uri.base.queryParameters.containsKey('e2e')) return const SizedBox.shrink();
    return Opacity(
      opacity: 0,
      alwaysIncludeSemantics: true,
      child: SizedBox(
        height: 1,
        child: Text('debug: ${_c.client.describe()}', overflow: TextOverflow.clip, maxLines: 1),
      ),
    );
  }

  /// The line under the felt: a pause and why, or a boot clock on the
  /// seat holding everyone up, or nothing special.
  Widget? _liveNote() {
    final game = _c.game;
    // Cut off from every relay comes first: it is the cause of most of
    // what follows, and the one thing the player can act on.
    final refused = _c.relayRefusal;
    if (refused != null) return _note('No relay will take this device\'s events: ${_short(refused)}');
    if (_c.pause == Pause.waitingForPeers) return _note('Waiting for the others to reconnect');
    if (_c.pause == Pause.waitingForJury) {
      if (_c.jury.live > 0) return _note('Asking the jury');
      if (_c.needsJuror) return _note('Nobody online to draw a jury from — waiting for one');
      return _note('Waiting for the jury');
    }
    if (_c.pause == Pause.openingHand) return _note("Opening a departed player's hand");
    if (_c.pause == Pause.waitingForLead) return _note('Nobody claims the 2♣ — the deal is stuck');
    final dealing = _c.dealNote;
    if (dealing != null) return _note(dealing);
    if (game.phase != Phase.playing && game.phase != Phase.passing) return null;
    // The seat everyone is waiting on, if it is a person other than me
    // and its clock has run out.
    for (var seat = 0; seat < seatCount; seat++) {
      if (seat == _c.mySeat || _c.personaAt(seat) != null) continue;
      if (_c.bootCountdownMs(seat) == null) continue;
      if (_c.canBoot(seat)) {
        // Sized to the line, which is thirty pixels: a button at its
        // default height was clipped top and bottom.
        return TextButton.icon(
          onPressed: () => _c.boot(seat),
          icon: const Icon(Icons.timer_off_outlined, size: 15),
          label: Text('Boot ${_c.names[seat]}', style: const TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
            foregroundColor: Palette.danger,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 26),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
      }
      // The seat's own badge shows its clock running; nothing more here.
    }
    return null;
  }

  static Widget _note(String text) =>
      Text(text, style: const TextStyle(fontSize: 12, color: Palette.chromeDim));

  /// A relay's reason, cut to the line.
  static String _short(String reason) => reason.length > 40 ? '${reason.substring(0, 39)}…' : reason;

  @override
  Widget build(BuildContext context) {
    final game = _c.game;
    // What the player has committed is already off the hand.
    // Nothing yet while a sealed table deals.
    final hand = game.knowsHand(_c.mySeat) ? _c.handShown : <engine.Card>[];
    final legal = _c.legalNow;
    final passing = _c.awaitingPass;
    final ended = _c.handJustEnded;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Stack(
            children: [
              TableLayout(
                header: TableHeader(
                  game: game,
                  menu: [
                    MenuAction('Leave the table', icon: Icons.logout, onSelected: _leave),
                    MenuAction('About', icon: Icons.info_outline, onSelected: () {
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutPage()));
                    }),
                  ],
                ),
                felt: Stack(
                  children: [
                    TableView(controller: _c),
                    Positioned(
                      left: 6,
                      top: 4,
                      child: _Presence(controller: _c),
                    ),
                  ],
                ),
                score: ScoreLine(controller: _c),
                below: _debugState(),
                action: ActionBar(controller: _c, onPass: _c.confirmPass, note: _liveNote()),
                hand: (landscape) => HandFan(
                  hand: hand,
                  onTap: _tapCard,
                  playable: passing ? hand.toSet() : legal,
                  selected: _c.selected,
                  dimUnplayable: _c.awaitingPlay,
                  forced: legal.length == 1 ? legal.first : null,
                  justReceived: game.tricksPlayed == 0 ? game.receivedBy(_c.mySeat).toSet() : const {},
                  spread: landscape ? 0.8 : 0.64,
                ),
              ),
              if (ended != null && !_c.done)
                HandOverSheet(
                  handNumber: ended.hand,
                  scores: ended.scores,
                  totals: ended.totals,
                  moonShooter: ended.moonShooter,
                  names: _c.names,
                  mySeat: _c.mySeat,
                  action: 'On with it',
                  onNext: _c.dismissHandSheet,
                ),
              if (_c.done && _c.gameOverDue)
                GameOverSheet(
                  game: game,
                  names: _c.names,
                  mySeat: _c.mySeat,
                  action: 'Home',
                  onNewGame: () => Navigator.of(context).pop(),
                ),
              if (!_c.amSeated && !_c.done) _Replaced(onBack: () => Navigator.of(context).pop()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who is still here: people at the table, out of those who sat down.
class _Presence extends StatelessWidget {
  const _Presence({required this.controller});

  final LiveController controller;

  @override
  Widget build(BuildContext context) {
    final humans = [for (var s = 0; s < seatCount; s++) if (controller.client.spec.seats[s] is HumanSeat) s];
    final here = controller.here;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$here of ${humans.length} here  ·  ${controller.client.spec.rated ? 'rated' : 'unrated'}',
        style: TextStyle(fontSize: 10.5, color: here == humans.length ? Palette.chromeDim : Palette.danger),
      ),
    );
  }
}

/// The table went on without you.
class _Replaced extends StatelessWidget {
  const _Replaced({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.62),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(22),
          padding: const EdgeInsets.all(22),
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: Felt.mid,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Palette.danger.withValues(alpha: 0.45)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('A bot took your seat',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Palette.danger)),
              const SizedBox(height: 6),
              const Text('The table could not hear from you, and went on.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Palette.chromeDim)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onBack,
                style: FilledButton.styleFrom(backgroundColor: Palette.gold, foregroundColor: Felt.dark),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
