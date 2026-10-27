/// A live table: the same screen as solo play, driven by the referee's
/// log. What is different is on the felt and its line — who is
/// connected, the clock on a seat that is holding everyone up, what the
/// table waits on — and what leaving means: a bot takes the seat.
library;

import 'dart:async';

import 'package:engine/engine.dart';
import 'package:flutter/material.dart' hide Card;
import 'package:go_router/go_router.dart';
import 'package:table/table.dart';

import '../feedback_page.dart';
import '../l10n/l10n.dart';
import '../net/address.dart' show driven;
import '../net/copy.dart';
import '../net/in_use.dart';
import '../net/remote_config.dart';
import '../net/share.dart';
import '../pages.dart';
import '../reaction_mute.dart';
import '../report.dart';
import '../table_model.dart' show SeatLooks, TableModelHand;
import '../table_page.dart' show ActionBar;
import '../theme.dart';
import '../ui/gone.dart';
import '../ui/hand_fan.dart';
import '../ui/header.dart';
import '../ui/overlays.dart';
import '../ui/reactions.dart';
import '../ui/reading_time.dart';
import '../ui/table_layout.dart';
import '../ui/table_view.dart';
import 'live_controller.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.controller, this.report = sendReport});

  final LiveController controller;

  /// Where a report of another player goes (report.dart).
  final ReportSender report;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  LiveController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    InUse.current.addListener(_steppedBack);
    // Whether this device hides the others' reactions, as it was left.
    unawaited(ReactionMute.current.load());
  }

  /// Another device of the account took it up, at this table's expense,
  /// or the account is suspended (net/in_use.dart): this device leaves
  /// the seat — its own word, by whatever path is still open to it; the
  /// relay has already cut it off — and the table gives the seat to a
  /// bot, as for anyone who leaves. What is said of it is said where
  /// the device lands: over everything for another device, on the
  /// subscribe page for a suspension.
  void _steppedBack() {
    if (!InUse.current.shut || !mounted) return;
    InUse.current.removeListener(_steppedBack);
    _leave();
  }

  /// The controller names the player and says what the deal is doing
  /// in the app's language, which is known once the page is in the tree.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.words = context.l10n;
  }

  void _changed() => setState(() {});


  @override
  void dispose() {
    InUse.current.removeListener(_steppedBack);
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  void _tapCard(Card card) {
    if (_c.awaitingPass) return _c.toggleSelected(card);
    if (!_c.awaitingPlay) return;
    final refusal = _c.playCard(card);
    if (refusal != null) _say(refusal);
  }

  /// The table's own address, for somebody to watch it from: the game
  /// as it is played, and the whole of it once it is over.
  Future<void> _shareToWatch() async {
    final link = tableLink(_c.spec.id);
    if (await shareLink(link)) return;
    await copyText(link.toString());
    if (mounted) _say(context.l10n.linkCopied);
  }

  /// The reactions to send (ui/reactions.dart), and the one picked said
  /// for this player — by this device, the account's device in use: one
  /// the account has been taken up from has already left its seat.
  Future<void> _pickReaction() async {
    final picked = await pickReaction(context);
    if (picked != null && mounted && !InUse.current.shut) _c.react(picked);
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        duration: readingTime(message),
        width: 260,
      ));
  }

  /// Holding another player's badge: what this device does with their
  /// picture, if they chose one, blocking them (pictures.dart), and
  /// reporting them to the people who run the game (report.dart).
  /// Nothing to offer for a bot or for your own seat. A blocked
  /// player's name is not shown here either.
  Future<void> _aboutPlayer(int seat) async {
    final about = _c.playerAt(seat);
    if (about == null) return;
    final pictures = _c.pictures;
    final picture = about.picture;
    final showIt = about.hidden || about.flagged;
    final shown = about.blocked ? context.l10n.blockedPlayer : about.name;
    final chosen = await showModalBottomSheet<_AboutPlayer>(
      context: context,
      backgroundColor: Felt.mid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (picture != null && pictures != null && !about.blocked) ...[
                if (about.flagged)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      sheet.l10n.pictureFlagged,
                      style: const TextStyle(fontSize: 13, color: Palette.chromeDim),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(sheet).pop(showIt ? _AboutPlayer.showPicture : _AboutPlayer.hidePicture),
                  style: TextButton.styleFrom(foregroundColor: showIt ? Palette.gold : Palette.danger),
                  child: Text(
                    showIt ? sheet.l10n.showPicture(about.name) : sheet.l10n.hidePicture(about.name),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  sheet.l10n.pictureChoiceNote,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Palette.chromeDim),
                ),
                const SizedBox(height: 12),
              ],
              TextButton(
                onPressed: () => Navigator.of(sheet).pop(_AboutPlayer.report),
                style: TextButton.styleFrom(foregroundColor: Palette.danger),
                child: Text(sheet.l10n.reportPlayer(shown), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              if (pictures != null) ...[
                TextButton(
                  onPressed: () => Navigator.of(sheet).pop(about.blocked ? _AboutPlayer.unblock : _AboutPlayer.block),
                  style: TextButton.styleFrom(foregroundColor: about.blocked ? Palette.gold : Palette.danger),
                  child: Text(
                    about.blocked ? sheet.l10n.unblockPlayer : sheet.l10n.blockPlayer(about.name),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                if (!about.blocked)
                  Text(
                    sheet.l10n.blockNote,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Palette.chromeDim),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (chosen) {
      case null:
        return;
      case _AboutPlayer.showPicture:
        await pictures?.show(about.key);
      case _AboutPlayer.hidePicture:
        await pictures?.hide(about.key);
      case _AboutPlayer.block:
        await pictures?.block(about.key);
      case _AboutPlayer.unblock:
        await pictures?.unblock(about.key);
      case _AboutPlayer.report:
        await showReport(context,
            about: about.key, name: about.name, shown: shown, picture: picture, table: _c.spec.id, send: widget.report);
    }
  }

  void _leave() {
    // Said, and gone. The beat the leaving needs to reach the wire is
    // the socket's to wait out, not the screen's (live_controller.dart)
    // — standing at a table you have left is the app arguing with you.
    if (_c.amSeated && !_c.done) _c.leave();
    Navigator.of(context).pop();
  }

  /// Leave the table, from its menu or by a phone's Back: asked first
  /// while the game goes on ([askToLeave]).
  Future<void> _askToLeave() async {
    if (!_c.inGame) return _leave();
    if (await askToLeave(context, _c) && mounted) _leave();
  }

  /// In a build being driven (net/address.dart), the rules' own account
  /// of the table (where the log is, what is owed, who has gone) sits
  /// in the accessibility tree, invisible: for a test or a tool driving
  /// the app, and for anyone reading a stuck table.
  Widget _debugState() {
    if (!driven(Uri.base)) return const SizedBox.shrink();
    return Opacity(
      opacity: 0,
      alwaysIncludeSemantics: true,
      child: SizedBox(
        height: 1,
        child: Text('debug: ${_c.client.rules.describe()}${_screenState()}', overflow: TextOverflow.clip, maxLines: 1),
      ),
    );
  }

  /// What the screen itself thinks it can do, beside what the table
  /// thinks. A table stuck from the outside is not always stuck in the
  /// protocol: a hand the screen will not draw is a turn the player
  /// cannot take, and the two look alike from off the device.
  String _screenState() {
    final game = _c.game;
    return '  screen: hand ${game.knowsHand(_c.mySeat) ? '${_c.handShown.length} cards' : 'not open here'}; '
        'my turn ${_c.client.awaitingMyPlay}; offered ${_c.awaitingPlay}; pass ${_c.awaitingPass}; ${_c.behind}\n';
  }

  /// Who is still here: people at the table, out of those who sat down,
  /// red while anybody is missing.
  ({String text, Color tone}) _presence(BuildContext context) {
    final humans = [for (var s = 0; s < seatCount; s++) if (_c.spec.seats[s] is HumanSeat) s];
    final here = _c.here;
    return (
      text: context.l10n.hereCount(here, humans.length, _c.spec.rated ? 'rated' : 'unrated'),
      tone: here == humans.length ? Palette.chromeDim : Palette.danger,
    );
  }

  /// The line under the felt: what the table waits on, if it waits on
  /// something a clock does not show, or what the deal is doing.
  Widget? _liveNote() {
    final l10n = context.l10n;
    // Turned away by the referee comes first: nothing this device says
    // reaches the table, and the player can act on it.
    final refused = _c.relayRefusal;
    if (refused != null) return _note(l10n.noRelayTakesEvents(_short(refused)));
    // Its own line down: whatever the table seems to wait on, it is
    // this device not hearing it, and the table waits for the line.
    if (_c.lineDown) return _note(l10n.connectionDown);
    if (_c.openingHand) return _note(l10n.openingDepartedHand);
    // A turn owed by somebody whose line is down. Their badge's clock
    // runs as it does for anyone slow; this says why nothing comes.
    if (_c.waitingOnSomeoneDown) return _note(l10n.waitingToReconnect);
    final dealing = _c.dealNote;
    if (dealing != null) return _note(dealing);
    return null;
  }

  static Widget _note(String text) =>
      Text(text, style: const TextStyle(fontSize: 12, color: Palette.chromeDim));

  /// A relay's reason, cut to the line.
  static String _short(String reason) => reason.length > 40 ? '${reason.substring(0, 39)}…' : reason;

  @override
  Widget build(BuildContext context) {
    // Back, while the game goes on, is leaving it, and asked like the
    // menu's Leave the table: a phone's here, a browser's where it
    // arrives, at the route (router.dart).
    return PopScope(
      canPop: !_c.inGame,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_askToLeave());
      },
      child: _screen(context),
    );
  }

  Widget _screen(BuildContext context) {
    // This device, not the game: its worker for the deal failed for
    // good, and it left the table rather than hold it up. The others
    // play on, a bot in this seat. Before the seat that is no longer
    // this player's, below: the leave lands at once, and what that
    // screen says — the table could not hear from you — is not what
    // happened.
    final cannotDeal = _c.client.cannotDeal;
    if (cannotDeal != null) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: Felt.gradient),
          child: SafeArea(
            child: _Failed(
              title: context.l10n.cannotDealTitle,
              label: context.l10n.cannotDealLabel,
              why: context.l10n.cannotDealWhy(cannotDeal),
              onHome: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      );
    }
    // A seat that is no longer this player's — their clock ran out, or
    // their line was down at their turn — shows no table at all: watching a bot play your cards
    // is not a thing to look at. Just what happened, and the way back.
    if (!_c.amSeated) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: Felt.gradient),
          child: SafeArea(child: _Replaced(onBack: () => Navigator.of(context).pop())),
        ),
      );
    }
    // A game that cannot go on ends, and says why: unscored, and
    // nothing left at the table to do but go.
    if (_c.failed) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: Felt.gradient),
          child: SafeArea(
            child: _Failed(
              title: context.l10n.connectionFailure,
              label: context.l10n.houseGone,
              why: context.l10n.houseGoneWhy,
              onHome: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      );
    }
    final game = _c.game;
    // What the player has committed is already off the hand.
    // Nothing yet while a sealed table deals.
    final hand = game.knowsHand(_c.mySeat) ? _c.handShown : <Card>[];
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
                // Where there is room beside the table, what a phone
                // has to hide goes in it (ui/gone.dart).
                rail: (width) => Gone(played: _c.playedThisHand, width: width),
                header: TableHeader(
                  game: game,
                  menu: [
                    MenuAction(context.l10n.shareToWatch, icon: Icons.visibility_outlined, onSelected: _shareToWatch),
                    MenuAction(context.l10n.leaveTheTable, icon: Icons.logout, onSelected: _askToLeave, danger: true),
                    MenuAction(context.l10n.tellUsWhatsBroken, icon: Icons.feedback_outlined, onSelected: () => showFeedback(context)),
                    MenuAction(context.l10n.about, icon: Icons.info_outline, onSelected: () {
                      openPage<void>(context, AppPage.about);
                    }),
                  ],
                ),
                // Who is here, in the felt's corner: the felt keeps it
                // clear of the seat across the table.
                felt: TableView(
                  controller: _c,
                  onHold: _aboutPlayer,
                  corner: _presence(context),
                  // Beside the player's own badge, while they sit here.
                  react: _c.canReact && !InUse.current.shut ? ReactionButton(onPressed: _pickReaction) : null,
                ),
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
                  // Where a card the player gives up goes, and where
                  // the ones they are given come from: the side of the
                  // screen the other end of the pass sits on. Through
                  // the play a card that leaves has been played, and
                  // rises to the table instead (ui/hand_fan.dart).
                  passTo: game.phase == Phase.passing ? passesTo(_c) : null,
                  receivedFrom: passesFrom(_c),
                  spread: HandFan.spreadFor(landscape: landscape),
                ),
              ),
              if (ended != null && !_c.done)
                HandOverSheet(
                  handNumber: ended.hand,
                  scores: ended.scores,
                  totals: ended.totals,
                  moonShooter: ended.moonShooter,
                  seats: _c.looks,
                  mySeat: _c.mySeat,
                  action: context.l10n.onWithIt,
                  onNext: _c.dismissHandSheet,
                ),
              if (_c.done && _c.gameOverDue)
                GameOverSheet(
                  game: game,
                  seats: _c.looks,
                  mySeat: _c.mySeat,
                  rating: _c.ratingChange,
                  // Another game the way this one began, where the front
                  // door knows how (lobby.dart); home beside it.
                  action: _c.canPlayAgain ? context.l10n.playAgain : context.l10n.home,
                  onNewGame: () => Navigator.of(context).pop(_c.canPlayAgain),
                  onHome: _c.canPlayAgain ? () => Navigator.of(context).pop(false) : null,
                  // The game is kept as it ends (lobby.dart), and its
                  // address is the table's: in place of this one, so back
                  // is home either way.
                  onSeeGame: () => context.pushReplacement(located(tablePath(_c.spec.id))),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tables whose question to leave is showing ([askToLeave]).
final _asking = Expando<bool>('asking to leave');

/// Whether to leave a live game that goes on, asked from the table's
/// menu and a phone's Back (the page) and from a browser's Back
/// (router.dart), with what leaving costs: the seat, a rated game's
/// place, and Play live's wait after a game left early
/// (left_early.dart) where there would be one. True for Leave. A way
/// out taken while the question shows is the question's to answer, so
/// it asks nothing more and stays.
Future<bool> askToLeave(BuildContext context, LiveController c) async {
  if (_asking[c] ?? false) return false;
  _asking[c] = true;
  try {
    final l10n = context.l10n;
    final wait = RemoteSettings.current.config.leftEarly;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.leaveTableTitle),
        content: Text([
          l10n.leaveTableBot,
          if (c.spec.rated) l10n.leaveTableRated,
          if (c.strangers && c.othersPlaying && wait > Duration.zero) l10n.leaveTableWait(wait.inMinutes),
        ].join(' ')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.stay)),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Palette.danger, foregroundColor: Felt.dark),
            child: Text(l10n.leave),
          ),
        ],
      ),
    );
    return sure == true;
  } finally {
    _asking[c] = null;
  }
}

/// The table went on without you.
/// A game this device can go no further in — a connection failure, or
/// a deal it can no longer run: what, why, and the way home.
class _Failed extends StatelessWidget {
  const _Failed({required this.title, required this.label, required this.why, required this.onHome});

  final String title;
  final String label;
  final String why;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    return Center(
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
            Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Palette.danger)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Palette.chrome)),
            const SizedBox(height: 8),
            Text(why, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onHome,
              style: FilledButton.styleFrom(backgroundColor: Palette.gold, foregroundColor: Felt.dark),
              child: Text(context.l10n.home),
            ),
          ],
        ),
      ),
    );
  }
}

class _Replaced extends StatelessWidget {
  const _Replaced({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
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
            Text(context.l10n.botTookYourSeat,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Palette.danger)),
            const SizedBox(height: 6),
            Text(context.l10n.tableCouldNotHear,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onBack,
              style: FilledButton.styleFrom(backgroundColor: Palette.gold, foregroundColor: Felt.dark),
              child: Text(context.l10n.back),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the sheet holding a player's badge opens can be asked to do.
enum _AboutPlayer { showPicture, hidePicture, block, unblock, report }
