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
import 'dart:math' show max, min;

import 'package:engine/engine.dart' hide Replay;
import 'package:flutter/material.dart' hide Card;
import 'package:table/table.dart';

import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/game_records.dart';
import 'net/in_use.dart';
import 'net/record_check.dart';
import 'net/remote_config.dart' show waits;
import 'net/report_error.dart';
import 'net/watching.dart';
import 'reaction_mute.dart';
import 'subscribe_page.dart';
import 'table_model.dart' show SeatReaction;
import 'theme.dart';
import 'ui/pip.dart';
import 'ui/player_icon.dart';
import 'ui/reactions.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.table, this.load = gameShownHere, this.check, this.watch});

  /// The table's id.
  final String table;

  /// How the record is fetched: the service's, and a test's to replace.
  /// Throws [GameNotShown] when the service will not show it here; then
  /// the page watches nothing either.
  final Future<KeptGame?> Function(String table) load;

  /// How it is checked: [checkRecord] unless a test says otherwise.
  final Stream<RecordCheck> Function(KeptGame game)? check;

  /// How a game still being played is watched: [watchTable] unless a
  /// test says otherwise.
  final Stream<Watched> Function(String table)? watch;

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
  const _Game(this.game, this.hands, {required this.done, this.winners = const []});
  final KeptGame game;

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
  StreamSubscription<Watched>? _watching;

  /// The players' reactions, held to the rules against the seats of the
  /// view on the screen (packages/table, reactions.dart), and what is
  /// showing at each seat until it goes.
  final _reactionRules = ReactionRules();
  final Map<int, ({SeatReaction shown, Timer gone})> _reacting = {};
  int _reactions = 0;

  @override
  void dispose() {
    _checking?.cancel();
    _watching?.cancel();
    for (final r in _reacting.values) {
      r.gone.cancel();
    }
    InUse.current.removeListener(_inUse);
    ReactionMute.current.removeListener(_muted);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // The suits' outlines while the game is fetched, not in the frame
    // that first draws a card.
    warmPips();
    InUse.current.addListener(_inUse);
    ReactionMute.current.addListener(_muted);
    unawaited(ReactionMute.current.load());
    _check();
  }

  void _muted() {
    if (mounted) setState(() {});
  }

  /// A reaction said at the table being watched: shown beside its seat
  /// for a moment if it is one, said by the device the view says holds
  /// that seat.
  void _heardReaction(HeardReaction heard) {
    final shown = _shown;
    if (shown is! _Live) return;
    final r = _reactionRules.hear(heard, seated: shown.view.seated, hand: shown.view.hand);
    if (r == null) return;
    _reacting.remove(r.seat)?.gone.cancel();
    final seat = r.seat;
    setState(() {
      _reacting[seat] = (
        shown: (reaction: r.reaction, n: ++_reactions),
        gone: Timer(ReactionRules.shownFor, () {
          if (mounted) setState(() => _reacting.remove(seat));
        }),
      );
    });
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
  Future<KeptGame?> _load() async {
    try {
      return await widget.load(widget.table);
    } on GameNotShown catch (e) {
      if (mounted) setState(() => _shown = _NotHere(e.why));
      rethrow;
    }
  }

  Future<void> _check() async {
    // Opened as the game ends, the copy may still be on its way from a
    // player's device (live/lobby.dart): asked again for a little while
    // (waits.recordSoon) before there is said to be none.
    KeptGame? record;
    try {
      record = await _load();
      // None kept: a game still being played, perhaps — watched while
      // the record is asked for a few more times, in case it is one just
      // over.
      if (record == null) _watch();
      for (var i = 0; record == null && i < _triesIn(waits.recordSoon) && mounted; i++) {
        await Future<void>.delayed(waits.recordAgain);
        record = await _load();
      }
    } on GameNotShown {
      unawaited(_watching?.cancel());
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
    _watching = (widget.watch ?? watchTable)(widget.table).listen((w) {
      if (!mounted || _checking != null) return;
      switch (w) {
        case Reacted(:final heard):
          _heardReaction(heard);
        case Viewed(view: final v):
          setState(() => _shown = _Live(v));
          if (v.over) {
            _watching?.cancel();
            _awaitRecord();
          }
      }
    });
  }

  /// How many times a record is asked for again over [span].
  static int _triesIn(Duration span) => max(1, span.inMilliseconds ~/ waits.recordAgain.inMilliseconds);

  /// The game is over: its record, once a player's device has sent it.
  Future<void> _awaitRecord() async {
    for (var i = 0; i < _triesIn(waits.recordFor) && mounted && _checking == null; i++) {
      await Future<void>.delayed(waits.recordAgain);
      if (!mounted || _checking != null) return;
      final KeptGame? record;
      try {
        record = await _load();
      } on GameNotShown {
        return;
      }
      if (record != null && mounted && _checking == null) return _verify(record);
    }
  }

  void _verify(KeptGame kept) {
    if (_checking != null) return;
    _watching?.cancel();
    // Who played, as soon as the record is read, and that it is being
    // checked; the hands as their checks come in.
    setState(() => _shown = _Game(kept, const [], done: false));
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
    }, onError: (Object error, StackTrace stack) {
      // A check that stopped with an error is one that could not be
      // made here, as on the web when its worker fails
      // (record_check_web.dart); the error itself is reported, not
      // left to stop the page.
      reportError(error, stack, where: 'record check');
      if (mounted) setState(() => _shown = const _Failed(null));
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

  /// Each checked hand's rows, made once (_review).
  final _handRows = Expando<_HandRows>();

  Widget _review(BuildContext context, _Game g) {
    final l10n = context.l10n;
    final spec = g.game.spec;
    String nameOf(int seat) => _seatName(l10n, g.game, seat);
    String seedOf(int seat) => switch (spec.seats[seat]) {
      BotSeat(:final persona) => persona.name,
      HumanSeat(:final account) => account,
    };
    final hands = g.hands;
    final hand = hands.isEmpty ? null : hands[_hand.clamp(0, hands.length - 1)];
    final totals = hand == null ? const <int>[] : hands.lastWhere((h) => h.totals.isNotEmpty, orElse: () => hand).totals;
    Color markOf(int seat) =>
        g.winners.contains(seat) ? Palette.win : (totals.isNotEmpty && totals[seat] >= spec.target ? Palette.danger : Palette.chrome);

    // A column in a scroll view, not a lazy list: a lazy list builds rows
    // it has not laid out, and the browser's focus walk, when the window
    // gains focus, asks a chip in one of them where it is. Drawn a piece
    // at a time, each in a frame of its own: who played, while the first
    // hand is checked; the hands and the first hand's title when it is;
    // its cards a few rows a frame after that (_HandRows).
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
                  const SizedBox(width: 14, height: 14, child: _Busy(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      hand == null ? l10n.checkingGame : l10n.stillCheckingGame,
                      style: const TextStyle(fontSize: 13, color: Palette.chromeDim),
                    ),
                  ),
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
          if (hand != null) ...[
            const SizedBox(height: 14),
            // Which hand.
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final h in hands)
                  _HandChip(
                    number: h.number,
                    selected: h.number == hand.number,
                    onTap: () => setState(() => _hand = h.number),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${l10n.handNumber(hand.number + 1)}  ·  ${l10n.passDirection(PassDirection.forHand(hand.number).name)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chrome),
            ),
            const SizedBox(height: 8),
            // The hand itself: made once for each hand as it is checked, so
            // the next hand's check arriving rebuilds the page around it and
            // not its hundred cards.
            _handRows[hand] ??= _HandRows(key: ValueKey(hand.number), game: g.game, hand: hand),
          ],
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
                  // A player's reaction, for a moment, beside their name;
                  // none where this device hides them.
                  if (_reacting[s]?.shown case final r? when !ReactionMute.current.value)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150, maxHeight: 30),
                        child: ReactionBubble(key: ValueKey(r.n), reaction: r.reaction, name: v.names[s], tail: AxisDirection.left),
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
          // The players' reactions show here as at the table; a watcher
          // has none to send, and can hide theirs.
          const SizedBox(height: 8),
          ReactionMuteSwitch(),
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

/// What a seat is called in [game]: a bot by its persona, a person by
/// the name their device gave, or by the seat.
String _seatName(AppLocalizations l10n, KeptGame game, int seat) => switch (game.spec.seats[seat]) {
  BotSeat(:final persona) => persona.name,
  HumanSeat() => game.names[seat] ?? l10n.seatPlayer(seat + 1),
};

/// A checked hand: each seat's thirteen as dealt, what it passed, and
/// the tricks in order.
///
/// A hundred cards and more, each a few widgets and a line of text, is
/// a frame that holds a slow phone's page still for seconds, so they
/// come a few rows a frame — a seat's thirteen, or a few tricks — from
/// the top, which is where the reader starts, beginning the frame after
/// the page around them. Between two frames the page answers whatever
/// has been waiting: a tap, the next hand's check.
class _HandRows extends StatefulWidget {
  const _HandRows({super.key, required this.game, required this.hand});

  final KeptGame game;
  final TableReplayHand hand;

  /// About as many cards as one frame draws of the hand.
  static const cardsAFrame = 16;

  /// How long the page is left to itself between two frames of rows: a
  /// frame asked for at once is drawn before anything else waiting, and
  /// a slow page would answer nothing until the last row was in.
  static const breath = Duration(milliseconds: 20);

  @override
  State<_HandRows> createState() => _HandRowsState();
}

class _HandRowsState extends State<_HandRows> {
  /// How many of the rows are drawn so far.
  int _shown = 0;
  bool _asked = false;

  /// The rows, made once for the hand and the words they are in: the
  /// same widgets frame after frame, so the rows already drawn are not
  /// built again with each new one.
  List<({Widget row, int cards})> _made = const [];
  (TableReplayHand, AppLocalizations)? _madeFor;

  List<({Widget row, int cards})> _rowsNow(BuildContext context) {
    final key = (widget.hand, context.l10n);
    if (_madeFor != key) {
      // Each row on a layer of its own, drawn once: the next rows, or the
      // next hand's check arriving, do not draw the rows already there.
      _made = [for (final r in _rows(context)) (row: RepaintBoundary(child: r.row), cards: r.cards)];
      _madeFor = key;
    }
    return _made;
  }

  /// The rows, each with how many cards it draws.
  List<({Widget row, int cards})> _rows(BuildContext context) {
    final l10n = context.l10n;
    final hand = widget.hand;
    String nameOf(int seat) => _seatName(l10n, widget.game, seat);
    return [
      // Each seat's thirteen as dealt; what it passed, marked.
      if (hand.dealt case final dealt?)
        for (var s = 0; s < seatCount; s++)
          (
            cards: dealt[s].length,
            row: Padding(
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
          ),
      (cards: 0, row: const SizedBox(height: 10)),
      // The tricks, in order: who led, what each played, who took it.
      for (final (i, trick) in hand.tricks.indexed)
        (
          cards: trick.length,
          row: Padding(
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
                    child: _Pip(card: p.card, by: nameOf(p.seat), taken: trick.length == seatCount && p.seat == _ReviewPageState._takerOf(trick)),
                  ),
                if (trick.length == seatCount)
                  Expanded(
                    child: Text(
                      nameOf(_ReviewPageState._takerOf(trick)),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim),
                    ),
                  ),
              ],
            ),
          ),
        ),
    ];
  }

  /// Up to the next row that takes the frame past [_HandRows.cardsAFrame]
  /// cards, and at least one row.
  void _more(List<({Widget row, int cards})> rows) {
    var cards = 0;
    do {
      cards += rows[_shown++].cards;
    } while (_shown < rows.length && cards + rows[_shown].cards <= _HandRows.cardsAFrame);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rowsNow(context);
    _shown = _shown.clamp(0, rows.length);
    // The next rows a moment after this frame is drawn — none in the
    // first, which draws the page around them — so that whatever has been
    // waiting for the page goes first, rather than frame on frame.
    if (_shown < rows.length && !_asked) {
      _asked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Timer(_HandRows.breath, () {
          _asked = false;
          if (mounted) setState(() => _more(_rowsNow(context)));
        });
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final r in rows.take(_shown)) r.row],
    );
  }
}

/// Which hand is shown: one of these for each hand checked, read and
/// pressed as a button named by its hand. Not a Material chip: a chip
/// is dozens of widgets and four animations, a long game has twenty,
/// and they are built on the page's thread while the rest of the game
/// is still being checked — on a slow phone, a second or more of a page
/// that answers nothing.
class _HandChip extends StatelessWidget {
  const _HandChip({required this.number, required this.selected, required this.onTap});

  /// The hand, from 0.
  final int number;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: context.l10n.handNumber(number + 1),
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? Palette.gold.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? Palette.gold : Palette.chromeDim.withValues(alpha: 0.5)),
        ),
        // As wide as its number, not as the line it is on.
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            '${number + 1}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Palette.gold : Palette.chrome,
            ),
          ),
        ),
      ),
    ),
  );
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
    child: ExcludeSemantics(child: _face(context)),
  );

  // One painted box a card, its rank's line laid out once for the whole
  // page and only drawn after (_rankLines): a hand on the page is a
  // hundred cards and more, and a line of text each, laid out afresh, was
  // most of what each new row cost a slow page.
  Widget _face(BuildContext context) {
    final rank = _rankLine(card, DefaultTextStyle.of(context).style, MediaQuery.textScalerOf(context));
    return CustomPaint(
      size: Size(rank.width + _pipSize + 1 + 2 * (_padX + _edge), max(rank.height, _pipSize) + 2 * (_padY + _edge)),
      painter: _CardFace(card: card, rank: rank, edge: taken ? Palette.gold : (passed ? Palette.danger : null)),
    );
  }

  static const _padX = 4.0, _padY = 2.0, _edge = 1.6, _pipSize = 11.0;

  /// Each rank's line, laid out, by what it is drawn in.
  static final _rankLines = <(String, Color, TextStyle, TextScaler), TextPainter>{};

  static TextPainter _rankLine(Card card, TextStyle base, TextScaler scaler) {
    final color = colorOf(card.suit);
    return _rankLines.putIfAbsent((card.rank.label, color, base, scaler), () {
      return TextPainter(
        text: TextSpan(text: card.rank.label, style: base.merge(TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color))),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
    });
  }
}

/// A card's face, small: the box, ringed in [edge] when there is one, the
/// rank's line and the suit drawn after it — as the table draws a suit
/// (ui/pip.dart), since a font's suit characters are not in every font
/// the page may have.
class _CardFace extends CustomPainter {
  const _CardFace({required this.card, required this.rank, this.edge});

  final Card card;
  final TextPainter rank;
  final Color? edge;

  @override
  void paint(Canvas canvas, Size size) {
    const e = _Pip._edge;
    final box = RRect.fromRectAndRadius((Offset.zero & size).deflate(e / 2), const Radius.circular(4));
    canvas.drawRRect(box, Paint()..color = Palette.cardFace);
    if (edge case final edge?) {
      canvas.drawRRect(box, Paint()..color = edge..style = PaintingStyle.stroke..strokeWidth = e);
    }
    final x = e + _Pip._padX;
    rank.paint(canvas, Offset(x, (size.height - rank.height) / 2));
    const pip = _Pip._pipSize;
    canvas.save();
    canvas.translate(x + rank.width + 1, (size.height - pip) / 2);
    canvas.scale(pip / 100);
    canvas.drawPath(pipPath(card.suit), Paint()..color = colorOf(card.suit)..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CardFace old) => old.card != card || old.rank != rank || old.edge != edge;
}

/// The spinner for a check under way, which can be most of a minute on
/// a phone: drawn on a layer of its own, so that turning it does not
/// draw the game around it again sixty times a second, and still for a
/// reader who asked for no motion.
class _Busy extends StatelessWidget {
  const _Busy({this.strokeWidth = 4});

  final double strokeWidth;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CircularProgressIndicator(
      strokeWidth: strokeWidth,
      value: MediaQuery.maybeOf(context)?.disableAnimations ?? false ? 0.3 : null,
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
          if (busy) ...[const _Busy(), const SizedBox(height: 16)],
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
