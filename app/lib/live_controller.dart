/// Drives the table's widgets from a live table: a [TableClient] over
/// a real transport, with the protocol deciding whose turn it is and
/// what has settled. The engine is the client's; this only adds what
/// a view needs — the pass selection, the score sheet of the hand just
/// finished, and the buttons a live table has that a solo one does
/// not: boot, and leave.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

import 'table_model.dart';

class LiveController extends ChangeNotifier implements TableModel {
  LiveController({
    required TableSpec spec,
    required this.seatNames,
    required Signer signer,
    required Transport transport,
    Clock? clock,
    this.ratingOf,
    this.onResult,
  }) : client = TableClient(spec: spec, signer: signer, transport: transport, clock: clock ?? WallClock()) {
    _sub = client.changes.listen((_) => _onChange());
    client.start();
  }

  final TableClient client;

  /// The humans' names by seat, from the lobby.
  final Map<int, String> seatNames;

  /// Ratings by key or persona name, on a rated table; null elsewhere.
  final Rating Function(String id)? ratingOf;

  /// Where a finished game's result goes, once, when the game ends.
  final void Function(GameResult result)? onResult;
  bool _reported = false;
  StreamSubscription<void>? _sub;
  final Set<Card> _selected = {};

  /// The score sheet of the hand just finished, until dismissed.
  ({int hand, List<int> scores, List<int> totals, int? moonShooter})? handJustEnded;
  int _shownHand = -1;
  Timer? _sheetTimer;

  void _onChange() {
    final last = client.lastHand;
    if (last != null && last.hand > _shownHand) {
      _shownHand = last.hand;
      handJustEnded = last;
      _sheetTimer?.cancel();
      _sheetTimer = Timer(const Duration(seconds: 6), dismissHandSheet);
    }
    if (!awaitingPass) _selected.clear();
    if (done && !_reported) {
      _reported = true;
      onResult?.call(GameResult.of(client.spec, client.holders, game.totals));
    }
    notifyListeners();
  }

  /// A seat's name with its rating: "Roxane 1520". The rating is the
  /// seat's as dealt — a bot that took over a leaver's seat shows the
  /// leaver's, since that is whose result it still is.
  String nameWithRating(int seat) {
    final r = ratingOf;
    if (r == null) return _plainName(seat);
    final id = switch (client.spec.seats[seat]) {
      HumanSeat(:final key) => key,
      BotSeat(:final persona) => persona.name,
    };
    return '${_plainName(seat)} ${r(id).shown}';
  }

  void dismissHandSheet() {
    _sheetTimer?.cancel();
    if (handJustEnded == null) return;
    handJustEnded = null;
    notifyListeners();
  }

  // ---- TableModel -------------------------------------------------------

  @override
  HeartsGame get game => client.game;

  @override
  int get mySeat => client.mySeat ?? 0;

  @override
  int positionOf(int seat) => (seat - mySeat + seatCount) % seatCount;

  @override
  int seatAt(int position) => (position + mySeat) % seatCount;

  /// Names, and on a rated table each name with its rating.
  @override
  List<String> get names => [for (var s = 0; s < seatCount; s++) ratingOf == null ? _plainName(s) : nameWithRating(s)];

  String _plainName(int s) => s == client.mySeat
      ? 'You'
      : switch (client.holders[s]) {
          BotSeat(:final persona) => persona.name,
          _ => seatNames[s] ?? 'Seat ${s + 1}',
        };

  @override
  Persona? personaAt(int seat) => switch (client.holders[seat]) {
        BotSeat(:final persona) => persona,
        _ => null,
      };

  @override
  Set<Card> get playedThisHand => Set.unmodifiable(client.played);

  @override
  Set<Card> get selected => Set.unmodifiable(_selected);

  @override
  bool get awaitingPass => client.awaitingMyPass;

  @override
  bool get canConfirmPass => awaitingPass && _selected.length == passSize;

  @override
  bool get awaitingPlay => client.awaitingMyPlay;

  @override
  Set<Card> get legalNow => awaitingPlay ? game.legalPlaysFor(mySeat).toSet() : const {};

  @override
  void toggleSelected(Card card) {
    if (!awaitingPass) return;
    if (!_selected.remove(card)) {
      if (_selected.length == passSize) return;
      _selected.add(card);
    }
    notifyListeners();
  }

  @override
  void confirmPass() {
    if (!canConfirmPass) return;
    client.pass(_selected.toList());
    _selected.clear();
    notifyListeners();
  }

  @override
  String? playCard(Card card) {
    if (!awaitingPlay) return null;
    if (!game.legalPlaysFor(mySeat).contains(card)) return refusalFor(game, mySeat, card);
    client.play(card);
    notifyListeners();
    return null;
  }

  // ---- what a live table has besides -----------------------------------

  bool get amSeated => client.amSeated;
  bool get done => client.done;
  TableState get tableState => client.tableState;
  Pause? get pause => client.pause;
  SeatState seatStateOf(int seat) => client.seatStateOf(seat);
  bool canBoot(int seat) => client.canBoot(seat);
  int? bootCountdownMs(int seat) => client.bootCountdownMs(seat);
  void boot(int seat) {
    client.boot(seat);
    notifyListeners();
  }

  void leave() {
    client.leave();
    notifyListeners();
  }

  /// Humans still at the table, by seat.
  int get participants => client.participants.length;

  /// The record so far, as the verifier sees it.
  Verification verification() => verifyRecord(client.spec, client.record, allowPartial: !done);

  @override
  void dispose() {
    _sheetTimer?.cancel();
    _sub?.cancel();
    client.close();
    super.dispose();
  }
}
