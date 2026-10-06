/// A table by its address (router.dart, `/table/ID`): the game
/// being played, watched, or the finished game, hand by hand.
///
/// The record is fetched by the table's id and checked here, on this
/// device, before a card of it is shown: every signature, every step of
/// the deal, every play against the rules (packages/table, record.dart).
/// The check runs off the page's thread (net/record_check.dart) and
/// each hand is shown as its check is done, the rest said to be still
/// in hand; a record that fails anywhere is shown as failing, whatever
/// was on the screen before.
///
/// A game still being played has no record yet: then the page watches
/// it instead (net/watching.dart) — the scores and each card as it is
/// played, as a seated player's device tells it — and when it is over,
/// fetches the record and checks it like any other.
///
/// What it shows of a finished game is what the check replayed — every
/// seat's thirteen as dealt, what was passed, each trick in order, and
/// the scores — so it is the game as it was played, whoever kept the
/// copy.
library;

import 'dart:async';
import 'dart:math' show min;

import 'package:engine/engine.dart' hide Replay;
import 'package:flutter/material.dart' hide Card;
import 'package:table/table.dart';

import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/game_records.dart';
import 'net/in_use.dart';
import 'net/record_check.dart';
import 'net/watching.dart';
import 'subscribe_page.dart';
import 'theme.dart';
import 'ui/pip.dart';
import 'ui/player_icon.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.table, this.load = gameShownHere, this.check, this.watch});

  /// The table's id.
  final String table;

  /// How the record is fetched: the service's, and a test's to replace.
  /// Throws [GameNotShown] when the service will not show it here; then
  /// the page watches nothing either.
  final Future<GameRecord?> Function(String table) load;

  /// How it is checked: [checkRecord] unless a test says otherwise.
  final Stream<RecordCheck> Function(GameRecord record)? check;

  /// How a game still being played is watched: [watchTable] unless a
  /// test says otherwise.
  final Stream<WatchedTable> Function(String table)? watch;

  /// How often a game just over is asked for again, and how many times,
  /// while its players' devices send it to be kept.
  static const recordAgain = Duration(seconds: 3);
  static const recordTries = 20;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

/// What the page has to show: still checking, nothing kept, a record
/// that failed, or the game.
sealed class _Shown {
  const _Shown();
}

class _Checking extends _Shown {
  const _Checking();
}

class _Nothing extends _Shown {
  const _Nothing();
}

class _Live extends _Shown {
  const _Live(this.view);
  final WatchedTable view;
}

/// Not for this device to look at: no subscription, the account in use
/// on another device, or the account's own game.
class _NotHere extends _Shown {
  const _NotHere(this.why);
  final NotShown why;
}

class _Failed extends _Shown {
  const _Failed(this.reason);
  final String? reason;
}

class _Game extends _Shown {
  const _Game(this.record, this.hands, {required this.done, this.winners = const []});
  final GameRecord record;

  /// The hands checked so far, in order.
  final List<TableReplayHand> hands;

  /// Whether the whole record is checked; [winners] only once it is.
  final bool done;
  final List<int> winners;
}

class _ReviewPageState extends State<ReviewPage> {
  _Shown _shown = const _Checking();
  int _hand = 0;
  StreamSubscription<RecordCheck>? _checking;
  StreamSubscription<WatchedTable>? _watching;

  @override
  void dispose() {
    _checking?.cancel();
    _watching?.cancel();
    InUse.current.removeListener(_inUse);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    InUse.current.addListener(_inUse);
    _check();
  }

  /// Another device of the account took it up: watching stops, as all
  /// live play here does (net/in_use.dart). A game already checked here
  /// stays on the screen; it is this device's own copy.
  void _inUse() {
    if (!mounted || !InUse.current.elsewhere || _watching == null) return;
    _watching?.cancel();
    _watching = null;
    if (_shown is _Live || _shown is _Nothing || _shown is _Checking) setState(() => _shown = const _NotHere(NotShown.elsewhere));
  }

  /// The record, or why this device is not shown it (null for none).
  Future<GameRecord?> _load() async {
    try {
      return await widget.load(widget.table);
    } on GameNotShown catch (e) {
      if (mounted) setState(() => _shown = _NotHere(e.why));
      rethrow;
    }
  }

  Future<void> _check() async {
    // Opened as the game ends, the copy may still be on its way from a
    // player's device (home_page.dart): asked again a few times before
    // there is said to be none.
    GameRecord? record;
    try {
      record = await _load();
      // None kept: a game still being played, perhaps — watched while
      // the record is asked for a few more times, in case it is one just
      // over.
      if (record == null) _watch();
      for (var i = 0; record == null && i < 4 && mounted; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        record = await _load();
      }
    } on GameNotShown {
      _watching?.cancel();
      _watching = null;
      return;
    }
    if (!mounted) return;
    if (record == null) {
      // Nothing yet; the watching goes on, and a game seen being played
      // takes the page over when it is.
      if (_shown is _Checking) setState(() => _shown = const _Nothing());
      return;
    }
    _verify(record);
  }

  void _watch() {
    _watching = (widget.watch ?? watchTable)(widget.table).listen((v) {
      if (!mounted || _checking != null) return;
      setState(() => _shown = _Live(v));
      if (v.over) {
        _watching?.cancel();
        _awaitRecord();
      }
    });
  }

  /// The game is over: its record, once a player's device has sent it.
  Future<void> _awaitRecord() async {
    for (var i = 0; i < ReviewPage.recordTries && mounted && _checking == null; i++) {
      await Future<void>.delayed(ReviewPage.recordAgain);
      if (!mounted || _checking != null) return;
      final GameRecord? record;
      try {
        record = await _load();
      } on GameNotShown {
        return;
      }
      if (record != null && mounted && _checking == null) return _verify(record);
    }
  }

  void _verify(GameRecord kept) {
    if (_checking != null) return;
    _watching?.cancel();
    setState(() => _shown = const _Checking());
    final hands = <int, TableReplayHand>{};
    List<TableReplayHand> inOrder() => [for (final n in hands.keys.toList()..sort()) hands[n]!];
    _checking = (widget.check ?? checkRecord)(kept).listen((c) {
      if (!mounted) return;
      switch (c) {
        case HandChecked(:final hand):
          hands[hand.number] = hand;
          setState(() => _shown = _Game(kept, inOrder(), done: false));
        case RecordChecked(:final ok, :final reason, :final winners):
          setState(() => _shown = ok ? _Game(kept, inOrder(), done: true, winners: winners) : _Failed(reason));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text(l10n.gameTitle)),
      body: SafeArea(
        child: switch (_shown) {
          _Checking() => _Note(l10n.checkingGame, busy: true),
          _Nothing() => _Note(l10n.noGameHere),
          _Failed(:final reason) => _Note(reason == null ? l10n.cantCheckGame : l10n.gameDoesNotCheck(reason), danger: true),
          _NotHere(:final why) => _notHere(context, why),
          _Game() && final g => _review(context, g),
          _Live(:final view) => _live(context, view),
        },
      ),
    );
  }

  /// Why this device is not shown the game, and the way on from there:
  /// a subscription, or taking the account back here.
  Widget _notHere(BuildContext context, NotShown why) {
    final l10n = context.l10n;
    return switch (why) {
      NotShown.noSubscription => _Note(l10n.reviewIsLivePlay, action: (l10n.subscribe, () => showSubscribe(context))),
      NotShown.elsewhere => _Note(l10n.liveOpenElsewhere, action: (l10n.useItHere, _useItHere)),
      NotShown.ownGame => _Note(l10n.reviewOwnGame),
    };
  }

  /// Takes the account up here (net/in_use.dart), and looks again.
  Future<void> _useItHere() async {
    await InUse.current.open(await Identity.signer());
    if (!mounted || InUse.current.standing != Use.here) return;
    setState(() => _shown = const _Checking());
    await _check();
  }

  Widget _review(BuildContext context, _Game g) {
    final l10n = context.l10n;
    final spec = g.record.spec;
    String nameOf(int seat) => switch (spec.seats[seat]) {
      BotSeat(:final persona) => persona.name,
      HumanSeat() => g.record.names[seat] ?? l10n.seatPlayer(seat + 1),
    };
    String seedOf(int seat) => switch (spec.seats[seat]) {
      BotSeat(:final persona) => persona.name,
      HumanSeat(:final account) => account,
    };
    final hands = g.hands;
    if (hands.isEmpty) return _Note(l10n.checkingGame, busy: true);
    final hand = hands[_hand.clamp(0, hands.length - 1)];
    final totals = hands.lastWhere((h) => h.totals.isNotEmpty, orElse: () => hand).totals;
    Color markOf(int seat) =>
        g.winners.contains(seat) ? Palette.win : (totals.isNotEmpty && totals[seat] >= spec.target ? Palette.danger : Palette.chrome);

    // A column in a scroll view, not a lazy list: a lazy list builds rows
    // it has not laid out, and the browser's focus walk, when the window
    // gains focus, asks a chip in one of them where it is.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The rest still being checked: what is shown has been, and a
          // failure later on takes the whole game off the screen.
          if (!g.done)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.stillCheckingGame, style: const TextStyle(fontSize: 13, color: Palette.chromeDim))),
                ],
              ),
            ),
          // Who played, and how it ended.
          for (var s = 0; s < seatCount; s++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  PlayerIcon(name: nameOf(s), seed: seedOf(s), size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      nameOf(s),
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: markOf(s)),
                    ),
                  ),
                  if (totals.isNotEmpty)
                    Text(
                      '${totals[s]}',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: markOf(s)),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          // Which hand.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final h in hands)
                ChoiceChip(
                  label: Text('${h.number + 1}'),
                  selected: h.number == hand.number,
                  onSelected: (_) => setState(() => _hand = h.number),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${l10n.handNumber(hand.number + 1)}  ·  ${l10n.passDirection(PassDirection.forHand(hand.number).name)}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chrome),
          ),
          const SizedBox(height: 8),
          // Each seat's thirteen as dealt; what it passed, marked.
          if (hand.dealt case final dealt?)
            for (var s = 0; s < seatCount; s++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 74,
                      child: Text(
                        nameOf(s),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 3,
                        runSpacing: 3,
                        children: [
                          for (final (i, c) in dealt[s].indexed) ...[
                            // A little room between suits.
                            if (i > 0 && dealt[s][i - 1].suit != c.suit) const SizedBox(width: 4),
                            _Pip(card: c, passed: hand.passedBy(s).contains(c)),
                          ],
                        ],
                      ),
                    ),
                    if (hand.scores.isNotEmpty)
                      SizedBox(
                        width: 30,
                        child: Text(
                          '+${hand.scores[s]}',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 12.5, color: hand.scores[s] == 0 ? Palette.chromeDim : Palette.danger),
                        ),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: 10),
          // The tricks, in order: who led, what each played, who took it.
          for (final (i, trick) in hand.tricks.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 74,
                    child: Text(l10n.trickNumber(i + 1), style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim)),
                  ),
                  for (final p in trick)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _Pip(card: p.card, by: nameOf(p.seat), taken: trick.length == seatCount && p.seat == _takerOf(trick)),
                    ),
                  if (trick.length == seatCount)
                    Expanded(
                      child: Text(
                        nameOf(_takerOf(trick)),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A game being played, as a seated player's device tells it: who is
  /// at the table and their scores, whose turn it is, and this hand's
  /// cards trick by trick. No hand is shown; nobody watching sees one.
  Widget _live(BuildContext context, WatchedTable v) {
    final l10n = context.l10n;
    final tricks = [for (var i = 0; i < v.plays.length; i += seatCount) v.plays.sublist(i, min(i + seatCount, v.plays.length))];
    final what = switch (v.phase) {
      Phase.dealing => l10n.dealingNow,
      Phase.passing => l10n.passingNow,
      _ => v.toPlay == null ? null : l10n.toPlayNow(v.names[v.toPlay!]),
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Palette.danger, borderRadius: BorderRadius.circular(4)),
                child: Text(l10n.liveNow, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${l10n.handNumber(v.hand + 1)}  ·  ${l10n.passDirection(PassDirection.forHand(v.hand).name)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chrome),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var s = 0; s < seatCount; s++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  PlayerIcon(name: v.names[s], seed: v.names[s], size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      v.names[s],
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: v.winners.contains(s) ? Palette.win : (v.toPlay == s ? Palette.gold : Palette.chrome),
                      ),
                    ),
                  ),
                  if (v.taken[s] > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text('+${v.taken[s]}', style: const TextStyle(fontSize: 13, color: Palette.danger)),
                    ),
                  Text('${v.totals[s]}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Palette.chrome)),
                ],
              ),
            ),
          if (what != null) ...[
            const SizedBox(height: 10),
            Text(what, style: const TextStyle(fontSize: 13.5, color: Palette.gold)),
          ],
          const SizedBox(height: 10),
          for (final (i, trick) in tricks.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 74,
                    child: Text(l10n.trickNumber(i + 1), style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim)),
                  ),
                  for (final p in trick)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _Pip(card: p.card, by: v.names[p.seat], taken: trick.length == seatCount && p.seat == _takerOf(trick)),
                    ),
                  if (trick.length == seatCount)
                    Expanded(
                      child: Text(
                        v.names[_takerOf(trick)],
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Text(l10n.watchingNote, style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim)),
        ],
      ),
    );
  }

  /// Who took a trick: the highest of the suit led.
  static int _takerOf(List<({int seat, Card card})> trick) {
    final led = trick.first.card.suit;
    return trick.where((p) => p.card.suit == led).reduce((a, b) => a.card.rank.value >= b.card.rank.value ? a : b).seat;
  }
}

/// A card, small: its rank and suit, red or black; ringed when it was
/// passed, gold when it took the trick.
class _Pip extends StatelessWidget {
  const _Pip({required this.card, this.by, this.passed = false, this.taken = false});

  final Card card;

  /// Who played it, in a trick: said with the card.
  final String? by;
  final bool passed;
  final bool taken;

  @override
  Widget build(BuildContext context) => Semantics(
    // Read as the table reads a card: "two of clubs". The suit is a
    // drawing, which says nothing to a screen reader.
    label: by == null ? context.l10n.card(card) : '${context.l10n.card(card)}, $by',
    child: ExcludeSemantics(child: _face()),
  );

  Widget _face() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: Palette.cardFace,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: taken ? Palette.gold : (passed ? Palette.danger : Colors.transparent), width: 1.6),
    ),
    // The suit drawn as the table draws it (ui/pip.dart): a font's
    // suit characters are not in every font the page may have.
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          card.rank.label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colorOf(card.suit)),
        ),
        const SizedBox(width: 1),
        Pip(suit: card.suit, size: 11, color: colorOf(card.suit)),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.busy = false, this.danger = false, this.action});

  final String text;
  final bool busy;
  final bool danger;

  /// A way on from here, as its label and what it does.
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[const CircularProgressIndicator(), const SizedBox(height: 16)],
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: danger ? Palette.danger : Palette.chrome),
          ),
          if (action case (final label, final onPressed)) ...[
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: Palette.gold,
                side: const BorderSide(color: Palette.gold, width: 1.4),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ],
      ),
    ),
  );
}
