/// A finished game, hand by hand (router.dart, `/play/table/ID`).
///
/// The record is fetched by the table's id and checked here, on this
/// device, before a card of it is shown: every signature, every step of
/// the deal, every play against the rules (packages/table, record.dart).
/// What it shows is what the check replayed — every seat's thirteen as
/// dealt, what was passed, each trick in order, and the scores — so it
/// is the game as it was played, whoever kept the copy.
library;

import 'package:engine/engine.dart' hide Replay;
import 'package:flutter/material.dart' hide Card;
import 'package:table/table.dart';

import 'crypto/deal.dart';
import 'l10n/l10n.dart';
import 'net/game_records.dart';
import 'theme.dart';
import 'ui/pip.dart';
import 'ui/player_icon.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.table, this.load = gameOf});

  /// The table's id.
  final String table;

  /// How the record is fetched: the service's, and a test's to replace.
  final Future<GameRecord?> Function(String table) load;

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

class _Failed extends _Shown {
  const _Failed(this.reason);
  final String? reason;
}

class _Game extends _Shown {
  const _Game(this.record, this.replay, this.winners);
  final GameRecord record;
  final TableReplay replay;
  final List<int> winners;
}

class _ReviewPageState extends State<ReviewPage> {
  _Shown _shown = const _Checking();
  int _hand = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // Opened as the game ends, the copy may still be on its way from a
    // player's device (home_page.dart): asked again a few times before
    // there is said to be none.
    var record = await widget.load(widget.table);
    for (var i = 0; record == null && i < 4 && mounted; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      record = await widget.load(widget.table);
    }
    if (!mounted) return;
    final kept = record;
    if (kept == null) return setState(() => _shown = const _Nothing());
    final crypto = dealCrypto;
    if (kept.spec.sealed && crypto == null) return setState(() => _shown = const _Failed(null));
    // A frame first, so "checking" is on the screen while it is done.
    await WidgetsBinding.instance.endOfFrame;
    final replay = TableReplay();
    final v = verifyRecord(
      kept.spec,
      kept.record,
      juries: kept.juries,
      releases: kept.releases,
      crypto: crypto,
      allowPartial: true,
      replay: replay,
    );
    if (!mounted) return;
    setState(() => _shown = v.ok ? _Game(kept, replay, v.winners) : _Failed(v.reason));
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
          _Game() && final g => _review(context, g),
        },
      ),
    );
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
      HumanSeat(:final key) => key,
    };
    final hands = g.replay.hands;
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
  const _Note(this.text, {this.busy = false, this.danger = false});

  final String text;
  final bool busy;
  final bool danger;

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
        ],
      ),
    ),
  );
}
