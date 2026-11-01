/// The table, as a function of its log (log.dart).
///
/// Every side applies the same rules to the same entries in the same
/// order, so every side comes to the same table: who holds each seat,
/// whose move it is, what was played, who has gone and why, and how the
/// game ended. Nothing here reads a clock but the referee's, on each
/// entry; nothing is voted on or guessed. The verifier is these rules
/// run over a kept log (record.dart).
///
/// Applying an entry at the referee's time t:
///
/// 1. **Deadlines first.** A turn open past its deadline at t is lost:
///    a person's removes the person (booted), the house's fails the
///    table. A person with a turn open, whose connection closed at
///    least [TableTiming.silenceMs] before t and has not opened again,
///    is removed (absent), without waiting on their clock.
/// 2. **Then the entry.** An event is taken when it is the first that
///    checks for a turn open now, from that turn's actor: the person in
///    the seat, or the house for a bot seat it holds. A leave removes
///    its author at once. A release is a piece of a departed person's
///    deal secret. Anything else stays in the log and changes nothing.
///
/// The house holds every bot seat that was a bot when the hand began.
/// A person's seat whose person goes is opened from the escrow — the
/// house's piece and any other person's — and played by everyone from
/// then on for the rest of that hand; from the next hand the house
/// holds it too. A seat no person holds any more, before its keys were
/// said, takes a secret everyone can compute, as a seat at a table with
/// no house does (docs/explanation/fair-deal.md).
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import 'events.dart';
import 'log.dart';
import 'pace.dart' show tablePaceCards;
import 'sealed_pass.dart';
import 'signing.dart';
import 'spec.dart';
import 'timing.dart';

/// How a person left their seat.
enum Exit {
  /// Their own signed leave.
  left,

  /// Their clock ran out at their turn.
  booted,

  /// Their connection had been closed for the table's silence at their
  /// turn.
  absent,

  /// The deal showed them to have said they held the lead card nowhere
  /// when they were dealt it.
  lied,
}

/// A person's seat given up: how, where in the log and when, and in
/// which hand.
class Removal {
  const Removal(this.exit, {required this.n, required this.t, required this.hand});
  final Exit exit;
  final int n;
  final int t;
  final int hand;
}

/// Where the game stands.
enum TableState {
  /// The log has not started: no start entry yet.
  waiting,
  playing,

  /// Somebody reached the target, and the last hand was audited.
  finished,

  /// No person is left at the table.
  ended,

  /// A turn of the house's ran out: the operator's service stopped
  /// answering, and nobody else can play a bot seat's cards. Or the
  /// house said it will not serve the table ([TableRules.refusal]).
  /// Nobody is rated.
  failed,
}

/// A turn open now: whose, since when, and until when.
class Owed {
  const Owed({required this.turn, required this.seat, required this.actor, required this.since, required this.allowance});
  final TurnId turn;
  final int seat;

  /// Who may take it: the person at the seat, or the house.
  final PublicKey actor;

  /// The referee's time it opened at.
  final int since;

  /// How long it may stay open.
  final int allowance;

  int get deadline => since + allowance;

  @override
  String toString() => '$turn seat $seat by ${actor.substring(0, 6)} since $since +$allowance';
}

class TableRules {
  TableRules({
    required this.tableId,
    this.crypto,
    this.myKey,
    this.mySeat,
    this.wrap,
    this.secretFor,
    this.keepSecret,
    this.worker,
    this.random,
    this.trace,
    this.readsOldGames = false,
  });

  /// The table the log is for: the start must name it.
  final String tableId;

  /// The deal's primitives, for a sealed table.
  final DealCrypto? crypto;

  /// The key this side acts with — a person's, or the house's, which
  /// also holds a piece of every person's escrow — or null for a
  /// verifier, which only reads.
  final PublicKey? myKey;

  /// The seat this side holds the deal secret of, where it holds one:
  /// a person's own while they sit there, or for the house the bot seat
  /// it plays.
  final int? mySeat;

  /// The secret [myKey] shares with another key, for the escrow
  /// (Signer.sharedSecretWith); null for a verifier, which opens
  /// nothing.
  final Uint8List Function(PublicKey other)? wrap;

  /// The deal secret this side's seat is to use for a hand, or null to
  /// draw one: a person's kept across a reload (journal.dart), the
  /// house's made from its own secret, so that a restart loses nothing.
  final Uint8List? Function(int hand)? secretFor;

  /// Told each hand's secret for this side's seat as it is drawn.
  final void Function(int hand, Uint8List secret)? keepSecret;

  /// Where the deal's slow calls are made, if not here.
  final DealWorker? worker;

  /// What this side's deal draws from: its secret where it has none
  /// kept, and the randomness of its proofs and shuffles. A secure
  /// generator but in the simulator.
  final Random? random;

  final void Function(String line)? trace;

  /// Whether this side also reads the games of earlier revisions of the
  /// deal's messages ([dealRevision]): the verifier of a record, which
  /// has to check games kept then, each by the revision its spec says.
  /// A table plays none, so that what a log is taken for is what the
  /// table took it for.
  final bool readsOldGames;

  // ---- what the log has said ---------------------------------------------

  /// The spec, from the log's start.
  TableSpec? get spec => _spec;
  TableSpec? _spec;

  /// Every entry taken, in order.
  final List<LogEntry> log = [];

  /// The log's running hash.
  final LogHash hash = LogHash();

  TableState get state => _state;
  TableState _state = TableState.waiting;

  bool get over => _state == TableState.finished || _state == TableState.ended || _state == TableState.failed;

  /// The house's word on how the game came out, once it is in the log
  /// and names the log as it stood when the game ended; or its word that
  /// it will not serve the table ([refusal]).
  TableEvent? get result => _result;
  TableEvent? _result;

  /// The house's word that it will not serve a table: a result that says
  /// failed and names the log as it stood after its start alone. The
  /// house says it as it reads the start, and cannot know where in the
  /// log the word will land, so it names what it has read; whatever came
  /// in between changes nothing about the word. A table the house refuses
  /// ends there, failed and unrated, at every side alike, and the
  /// referee, which asks for the house until it has said a result, stops
  /// asking (service/do/referee.mjs). Taken only from the house and only
  /// while the table is being played: a table that has ended on its own
  /// keeps its end. Its totals are zero and unread. Null before the
  /// log's start.
  Map<String, Object?>? get refusal => _startHash == null
      ? null
      : {'n': 1, 'hash': _startHash, 'state': TableState.failed.name, 'totals': List.filled(seatCount, 0)};

  /// The log's hash as it stood after its start.
  String? _startHash;

  /// How many entries the log had, and its hash, when the game ended:
  /// what the house's result has to name.
  int? get endN => _endN;
  String? get endHash => _endHash;
  int? _endN;
  String? _endHash;

  void _markEnd() {
    if (!over || _endN != null) return;
    _endN = hash.count;
    _endHash = hash.value;
  }

  /// The game, as this side can see it.
  HeartsGame get game => _game!;
  HeartsGame? _game;

  /// Who holds each seat now.
  List<SeatHolder> get holders => List.unmodifiable(_holders);
  late List<SeatHolder> _holders;

  /// Who held each seat when this hand began: what the hand's deal is
  /// made for, whoever has gone since.
  late List<SeatHolder> _dealtTo;

  /// Each person removed, by seat.
  Map<int, Removal> get removals => Map.unmodifiable(_removals);
  final Map<int, Removal> _removals = {};

  /// What is owed now, by seat.
  Map<int, Owed> get owed => Map.unmodifiable(_owed);
  final Map<int, Owed> _owed = {};

  /// Departed persons whose hands are waiting to be opened from the
  /// escrow, by seat, with when they went.
  Map<int, int> get openings => Map.unmodifiable(_openings);
  final Map<int, int> _openings = {};

  /// Each seat's bank this hand, in milliseconds.
  List<int> get banks => List.unmodifiable(_banks);
  final List<int> _banks = List.filled(seatCount, 0);

  /// How long the person at [seat] took over each of their last cards
  /// ([tablePaceCards] at most), from the turn's opening to the card, by
  /// the referee's clock, oldest first: how quick the people at the table
  /// are, which the house keeps its bots up with (house.dart). Empty for
  /// a seat a bot holds, and for a person's before their first card.
  List<int> cardTimesOf(int seat) => List.unmodifiable(_cardTimes[seat]);
  final List<List<int>> _cardTimes = List.generate(seatCount, (_) => <int>[]);

  /// When each key's connection to the log closed, while it is closed.
  Map<PublicKey, int> get down => Map.unmodifiable(_down);
  final Map<PublicKey, int> _down = {};

  /// The referee's time at the last entry taken.
  int get now => _now;
  int _now = 0;

  /// The cards played this hand, for the bots.
  final Set<Card> played = {};

  /// This hand's deal, at a sealed table, and every hand's so far.
  DealSession? get deal => _deal;
  DealSession? _deal;
  DealSession? dealOf(int hand) => _deals[hand];
  final Map<int, DealSession> _deals = {};

  /// The events taken, in order: what the record replays.
  final List<TableEvent> taken = [];

  /// Every pass and play, said or worked out, in the order the table took
  /// them: what a view of the table runs behind.
  final List<Move> moves = [];

  /// Called after every change, once the change is whole.
  void Function()? onChange;

  /// Told of each hand played out, audited and opened, as it moves on
  /// to the next or ends the game: the game at its end, and the hand's
  /// deal. What a kept game is shown hand by hand from (record.dart).
  void Function(HeartsGame game, DealSession? deal)? onHandOver;

  /// Told the number of each entry once it is taken and the table has
  /// settled after it: where a check that every side came to the same
  /// table after every entry ([settledView]) looks.
  void Function(int n)? onSettled;
  int _settledAt = -1;

  /// Told the table as it stands after each change a person could see:
  /// what a view of the table shows, one change at a time and at a pace
  /// of its own, without working anything out (app/lib/live,
  /// live_controller.dart). Nothing is copied while nobody listens.
  void Function(Frame frame)? onFrame;

  void _frame(FrameChange change, [int? seat]) {
    final f = onFrame;
    if (f == null) return;
    f(Frame(change, game: game.lookahead(), holders: List.unmodifiable(_holders), played: Set.unmodifiable(Set.of(played)), seat: seat));
  }

  TableTiming get timing => _spec!.timing;

  // ---- feeding ------------------------------------------------------------

  final Queue<LogEntry> _queue = Queue();
  bool _pumping = false;
  final Set<String> _working = {};

  /// Why this side cannot deal, once its worker failed for good.
  String? get cannotDeal => _cannotDeal;
  String? _cannotDeal;

  /// This side's deal worker failed for good, [why], at one of its jobs:
  /// one of these rules' own, or one for this side's own step of the deal
  /// (client.dart). Every job fails from then on (work.dart), so this
  /// side can deal no more.
  void workerFailed(Object why) {
    _cannotDeal = '$why';
    trace?.call('cannot deal: $why');
    onChange?.call();
  }

  late final PreparedDeal? _prepared = worker == null || crypto == null ? null : PreparedDeal(crypto!);

  /// Takes the entries in order, as they come: an entry out of order is
  /// a bug in whoever fed it.
  void feed(LogEntry e) {
    final expected = log.length + _queue.length;
    if (e.n != expected) throw StateError('entry ${e.n} fed where $expected was due');
    _queue.add(e);
    _pump();
  }

  /// The entries fed and not yet taken: those waiting on the deal's
  /// slow calls.
  int get waitingToTake => _queue.length;

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    var changed = false;
    try {
      while (true) {
        if (_cannotDeal != null) break;
        if (!_settle()) break;
        _owe();
        _markEnd();
        if (log.length - 1 > _settledAt) {
          _settledAt = log.length - 1;
          onSettled?.call(_settledAt);
        }
        if (_queue.isEmpty) break;
        final e = _queue.first;
        if (!_ready(_jobsFor(e))) break;
        _queue.removeFirst();
        _take(e);
        changed = true;
      }
    } finally {
      _pumping = false;
    }
    if (changed || _settledSince) {
      _settledSince = false;
      onChange?.call();
    }
  }

  bool _settledSince = false;

  /// Whether every slow call in [jobs] has its answer here. Those that
  /// do not are sent to the worker; the pump goes on when they are back.
  bool _ready(List<DealJob> jobs) {
    final p = _prepared;
    final w = worker;
    if (p == null || w == null) return true;
    var all = true;
    for (final job in jobs) {
      if (p.has(job)) continue;
      all = false;
      if (!_working.add(job.key)) continue;
      w.run(job, done: (answer) {
        _working.remove(job.key);
        p.put(job, answer);
        _deal?.resume();
        _settledSince = true;
        _pump();
      }, failed: workerFailed);
    }
    return all;
  }

  /// The slow checks taking [e] will make.
  List<DealJob> _jobsFor(LogEntry e) {
    final ev = e.event;
    final d = _deal;
    if (ev == null || d == null || ev.kind != EventKind.deal || _mine.contains(ev.id)) return const [];
    if (ev.hand != game.handNumber) return const [];
    return d.workToTake(ev.round, Map<String, Object?>.from(ev.body));
  }

  /// The events this side made itself: taken without checking.
  final Set<String> _mine = {};

  /// [e] is this side's own: it will be taken as made.
  void made(TableEvent e) {
    _mine.add(e.id);
    if (e.kind == EventKind.deal) _madeSteps.add(e.id);
  }

  /// This side's deal steps of the hand, made and not yet taken: each
  /// changed the hand's session as it was made.
  final Set<String> _madeSteps = {};

  // ---- taking an entry ----------------------------------------------------

  void _take(LogEntry e) {
    hash.add(e);
    log.add(e);
    if (e.n == 0) return _start(e);
    if (_state != TableState.playing) {
      // The house's word may follow the end.
      if (_state != TableState.waiting && _result == null) _takeResult(e.event);
      return;
    }
    if (e.t > _now) _now = e.t;
    _expire();
    if (_state != TableState.playing) return;
    if (e.up != null) _down.remove(e.up);
    if (e.down != null) _down[e.down!] = e.t;
    final ev = e.event;
    if (ev != null) _takeEvent(ev);
    // Logged by the referee and read by no side: it changes nothing,
    // and says so.
    final unread = e.unread;
    if (unread != null) trace?.call('entry #${e.n} does not read as an event (${unread['kind']} by ${'${unread['author']}'.padRight(6).substring(0, 6)}), and changes nothing');
    _settledSince = true;
  }

  /// Whether this side reads the deal of [spec] as it says it is made:
  /// by the revision of this build, or, for a verifier, an earlier one.
  bool _speaks(TableSpec spec) => spec.deal == dealRevision || (readsOldGames && spec.deal < dealRevision);

  void _start(LogEntry e) {
    final ev = e.event;
    final spec = ev == null || ev.kind != EventKind.start ? null : TableSpec.parse(ev.body['spec']);
    if (spec == null ||
        spec.id != tableId ||
        spec.seatOf(ev!.author) == null ||
        (spec.sealed && (spec.house == null || crypto == null || !_speaks(spec)))) {
      trace?.call('the log does not start a table: ${e.event}');
      _state = TableState.failed;
      return;
    }
    _spec = spec;
    _startHash = hash.value;
    _now = e.t;
    _holders = List.of(spec.seats);
    _game = HeartsGame(seed: spec.seed, sealed: spec.sealed, target: spec.target);
    _state = TableState.playing;
    _startHand();
  }

  /// The house's word on the game: kept once the game is over, when it
  /// names the log as it stood when the game ended.
  void _takeResult(TableEvent? ev) {
    if (ev == null || ev.kind != EventKind.result || ev.author != _spec?.house) return;
    if (ev.body['n'] != _endN || ev.body['hash'] != _endHash || ev.body['state'] != _state.name) return;
    final totals = [for (final t in ev.body['totals'] as List) t as int];
    if (totals.length != seatCount || !Iterable<int>.generate(seatCount).every((s) => totals[s] == game.totals[s])) return;
    _result = ev;
  }

  /// The house's word that it will not serve the table ([refusal]): the
  /// table fails here. A word that says anything else at a table being
  /// played is not read.
  void _takeRefusal(TableEvent ev) {
    final body = refusal!;
    if (ev.author != _spec!.house || ev.body['n'] != body['n'] || ev.body['hash'] != body['hash'] || ev.body['state'] != body['state']) return;
    _result = ev;
    _fail();
  }

  void _takeEvent(TableEvent ev) {
    final spec = _spec!;
    if (ev.table != spec.id) return;
    switch (ev.kind) {
      case EventKind.leave:
        final seat = ev.seat;
        if (seat < 0 || seat >= seatCount) return;
        final h = _holders[seat];
        if (h is HumanSeat && h.key == ev.author) _remove(seat, Exit.left);
      case EventKind.release:
        _takeRelease(ev);
      case EventKind.deal || EventKind.pass || EventKind.play:
        _takeMove(ev);
      case EventKind.result:
        _takeRefusal(ev);
      case EventKind.start:
        break;
    }
  }

  /// Whether this side checks [ev], or takes it as it is: its own.
  bool _checked(TableEvent ev) => !_mine.contains(ev.id);

  void _takeMove(TableEvent ev) {
    final seat = ev.seat;
    if (seat < 0 || seat >= seatCount) return;
    final o = _owed[seat];
    if (o == null || o.actor != ev.author || o.turn != ev.turn) return;
    final check = _checked(ev);
    if (check && ev.kind == EventKind.deal && _deal?.mySeat == seat && _madeSteps.isNotEmpty) {
      // A step for this side's own seat that this side did not make: an
      // earlier run's, said before a reload or a restart, taken where
      // this run had made a step of its own. The hand's session is built
      // again from what the log has taken, without it.
      trace?.call('an earlier run\'s step for seat $seat: the hand\'s deal built again from the log');
      _rebuild(mine: true);
    }
    final ok = switch (ev.kind) {
      EventKind.deal => _takeDealStep(ev, seat, check),
      EventKind.pass => _takePass(ev, seat, check),
      EventKind.play => _takePlay(ev, seat, check),
      _ => false,
    };
    if (!ok) {
      trace?.call('not taken: $ev for ${o.turn}');
      return;
    }
    if (o.turn.isPass || o.turn.isPlay) {
      if (_holders[seat] is HumanSeat) {
        final took = (_pausedAt ?? _now) - o.since;
        final spent = took - timing.bank.graceOf(o.turn);
        if (spent > 0) _banks[seat] = max(0, _banks[seat] - spent);
        if (o.turn.isPlay) {
          final times = _cardTimes[seat]..add(took);
          if (times.length > tablePaceCards) times.removeAt(0);
        }
      }
    }
    taken.add(ev);
    _madeSteps.remove(ev.id);
    _owed.remove(seat);
  }

  // ---- deadlines ------------------------------------------------------------

  /// Every turn lost by [_now], in seat order, one at a time: each loss
  /// changes what is owed next.
  void _expire() {
    while (_state == TableState.playing) {
      var lost = false;
      for (final e in _openings.entries) {
        if (_now > e.value + timing.bank.fixedMs) {
          trace?.call('seat ${e.key}\'s hand was not opened in time');
          _unopened();
          lost = true;
          break;
        }
      }
      // Every clock stops while a departed hand is opened.
      if (!lost && _pausedAt != null) return;
      for (var s = 0; s < seatCount; s++) {
        final o = _owed[s];
        if (o == null) continue;
        final house = o.actor == _spec!.house && _holders[s] is BotSeat;
        if (_now > o.deadline) {
          if (house) {
            trace?.call('the house let ${o.turn} run out');
            _fail();
            return;
          }
          _remove(s, Exit.booted, why: '$o, out at $_now');
          lost = true;
          break;
        }
        final since = _down[o.actor];
        if (!house && since != null && _now - since >= timing.silenceMs) {
          _remove(s, Exit.absent);
          lost = true;
          break;
        }
      }
      if (!lost) return;
      if (!_settle()) return;
      _owe();
    }
  }

  /// A departed hand nobody opened in time: the house's piece or the
  /// other people's never came. Nobody can play those cards, so the
  /// hand is given up, as a hand with a lie in it is, and the house
  /// holds the seat from the next; a hand already played out stands. It
  /// does not end the game: a person left to release a piece who will
  /// not cannot turn a game into one nobody is rated for.
  void _unopened() {
    _openings.clear();
    _pausedAt = null;
    if (game.phase == Phase.handOver || game.phase == Phase.gameOver) return;
    trace?.call('hand ${game.handNumber} given up: a departed hand could not be opened');
    game.abandonHand();
    _startHand();
    _frame(FrameChange.givenUp);
  }

  void _fail() {
    _state = TableState.failed;
    _owed.clear();
  }

  // ---- seats ------------------------------------------------------------

  /// Who takes [seat]'s turns this hand: its person, the house for a bot
  /// seat it holds, or nobody — a bot every side works out.
  PublicKey? actorOf(int seat) {
    final h = _holders[seat];
    if (h is HumanSeat) return h.key;
    return _houseHolds(seat, game.handNumber) ? _spec!.house : null;
  }

  /// Whether the house holds [seat] at [hand]: a sealed table's bot seat
  /// that was a bot when the hand began.
  bool _houseHolds(int seat, int hand) {
    if (!_spec!.sealed || _holders[seat] is! BotSeat) return false;
    final r = _removals[seat];
    return r == null || r.hand < hand;
  }

  /// Whether a person is left at the table.
  bool get anyoneHere => _holders.any((h) => h is HumanSeat);

  /// [why], for the trace: the turn that ran out, for a seat booted.
  void _remove(int seat, Exit how, {String? why}) {
    final h = _holders[seat];
    if (h is! HumanSeat) return;
    _holders[seat] = BotSeat(_spec!.replacementFor(seat));
    _removals[seat] = Removal(how, n: log.length - 1, t: _now, hand: game.handNumber);
    _owed.remove(seat);
    _cardTimes[seat].clear();
    trace?.call('seat $seat ${how.name} at #${log.length - 1}${why == null ? '' : ': $why'}');
    final d = _deal;
    if (d != null) {
      // This side's own seat gone: its session built again from the log,
      // so that nothing of the seat's it made and the log never took
      // counts. It keeps the seat's secret, and still opens what was
      // sealed to the seat; the table goes by what is in the open.
      if (d.mySeat == seat) _rebuild(mine: true);
      _op((d) => d.seatLeft(seat));
      if (_keyed(seat) && !_deal!.knowsInTheOpen(seat)) {
        _openings[seat] = _now;
        _pausedAt ??= _now;
      }
    }
    if (!anyoneHere) {
      _state = TableState.ended;
      _owed.clear();
    }
    _frame(FrameChange.seat, seat);
  }

  /// The hand's deal built again from what the log has taken, and
  /// nothing this side made that it has not: as a follower's when this
  /// side's seat is gone, or as its own seat's.
  void _rebuild({required bool mine}) {
    final hand = game.handNumber;
    // The seat's secret as this side holds it, where nothing kept says
    // otherwise: a session that drew another would open none of the
    // seat's own cards.
    final again = _session(hand, mine: mine, held: mine ? _deal?.mySecret : null);
    for (final op in _ops) {
      op(again);
    }
    _deal = again;
    _deals[hand] = again;
    _madeSteps.clear();
  }

  /// Everything done to this hand's deal from the log, in order: what a
  /// session is built again from ([_rebuild]).
  final List<void Function(DealSession)> _ops = [];

  /// Does [f] to the hand's deal, and keeps it for a session built again.
  void _op(void Function(DealSession) f) {
    _ops.add(f);
    f(_deal!);
  }

  /// [f] tried on the hand's deal, and kept for a session built again
  /// where it took.
  bool _try(bool Function(DealSession) f) {
    final ok = f(_deal!);
    if (ok) _ops.add((d) => f(d));
    return ok;
  }

  // ---- the hand ---------------------------------------------------------

  void _startHand() {
    played.clear();
    _owed.clear();
    _since.clear();
    _openings.clear();
    _pausedAt = null;
    for (var s = 0; s < seatCount; s++) {
      _banks[s] = timing.bank.bankMs;
    }
    _progress = _Progress();
    _ops.clear();
    _madeSteps.clear();
    _dealtTo = List.of(_holders);
    if (!_spec!.sealed) return;
    _deal = _session(game.handNumber, mine: true);
    _deals[game.handNumber] = _deal!;
  }

  /// A session for [hand]'s deal: holding this side's seat's secret
  /// where [mine] and this side holds one there — the one kept for the
  /// hand ([secretFor]), else [held], else one drawn now.
  DealSession _session(int hand, {required bool mine, Uint8List? held}) {
    final spec = _spec!;
    final me = mine ? _mySeatAt(hand) : null;
    final house = spec.house!;
    final secret = me == null ? null : secretFor?.call(hand) ?? held;
    final d = DealSession(
      _prepared ?? crypto!,
      tableId: spec.id,
      tableSeed: spec.seed,
      hand: hand,
      seats: [
        for (var s = 0; s < seatCount; s++)
          switch (_dealtTo[s]) {
            HumanSeat(:final key) => HumanDealSeat(key),
            BotSeat() => BotDealSeat(key: _houseHolds(s, hand) ? house : null),
          },
      ],
      leadCard: twoOfClubs.index,
      mySeat: me,
      myKey: myKey,
      wrap: wrap,
      // A person's seat escrows to the house beside the other people; a
      // bot seat the house holds escrows to nobody, since nobody else
      // may see its cards.
      custodians: me != null && _dealtTo[me] is HumanSeat ? [house] : const [],
      readsOldPasses: _spec!.deal < dealRevision,
      mySecret: secret,
      random: random,
    )..log = (l) => trace?.call('deal: $l');
    final drawn = d.mySecret;
    if (me != null && drawn != null && secret == null) keepSecret?.call(hand, drawn);
    return d;
  }

  /// The seat this side holds the secret of at [hand], if any: its own
  /// as the hand was dealt, whoever holds it since.
  int? _mySeatAt(int hand) {
    final s = mySeat;
    if (s == null || myKey == null) return null;
    final h = _dealtTo[s];
    if (h is HumanSeat) return h.key == myKey ? s : null;
    return myKey == _spec!.house && _houseHolds(s, hand) ? s : null;
  }

  /// Whether [seat] holds a key of its own in this hand's deal: its
  /// steps come from its actor, not from everyone's working out.
  bool _keyed(int seat) {
    final d = _deal;
    if (d == null) return false;
    return switch (d.seats[seat]) {
      HumanDealSeat() => true,
      BotDealSeat(:final key) => key != null,
    };
  }

  /// Whether [seat]'s steps are everyone's to work out now: unkeyed, or
  /// a departed person's opened from the escrow.
  bool _public(int seat) => !_keyed(seat) || (_removals.containsKey(seat) && _removals[seat]!.hand == game.handNumber && _deal!.knowsInTheOpen(seat));

  /// What the log has taken of the hand's deal, seat by seat.
  _Progress _progress = _Progress();

  // ---- settling --------------------------------------------------------

  /// Works out everything nobody has to say, and moves the hand on as
  /// far as it can: a bot seat everyone works out, the deal dealt, a
  /// trick swept, a hand over. False while the deal waits on a slow call.
  bool _settle() {
    while (_state == TableState.playing) {
      final d = _deal;
      if (d != null) {
        _resolveOpenings();
        if (!_ready(d.wanted)) return false;
      }
      if (!_step()) return true;
    }
    return true;
  }

  void _resolveOpenings() {
    final d = _deal!;
    _openings.removeWhere((seat, _) => d.knowsInTheOpen(seat) || !_keyed(seat));
    final paused = _pausedAt;
    if (_openings.isNotEmpty || paused == null) return;
    // Each turn open now had its clock stopped for the part of the
    // pause it was open in.
    for (final t in _since.keys.toList()) {
      final since = _since[t]!;
      _since[t] = since + _now - max(since, paused);
    }
    _pausedAt = null;
  }

  /// When the clocks stopped for a departed hand to be opened, while
  /// one is.
  int? _pausedAt;

  /// Whether every clock is stopped while a departed hand is opened.
  bool get paused => _pausedAt != null;

  /// The referee's time the clocks stopped at, while they are stopped.
  int? get pausedAt => _pausedAt;

  /// One move nobody says; false when there is none to make.
  bool _step() {
    final g = game;
    final d = _deal;
    switch (g.phase) {
      case Phase.dealing:
        return _dealt();
      case Phase.passing:
        for (var s = 0; s < seatCount; s++) {
          if (g.hasPassed(s) || actorOf(s) != null) continue;
          if (d != null && !_public(s)) continue;
          if (!_seeHand(s)) continue;
          final cards = Bot(persona: (_holders[s] as BotSeat).persona).choosePass(g.handOf(s));
          if (d != null) {
            final to = (s + g.passDirection.seatOffset) % seatCount;
            final positions = [for (final c in cards) d.positionOf(s, c.index)!];
            _op((d) => d.passOpen(s, to, positions));
            _declareLead();
          }
          g.setPass(s, cards);
          moves.add(Move(g.handNumber, s, passed: cards));
          _frame(FrameChange.passed, s);
          return true;
        }
        return false;
      case Phase.playing:
        if (g.trick.length == seatCount) {
          g.collectTrick();
          _frame(FrameChange.collected);
          return true;
        }
        final s = g.currentSeat;
        if (s == null || actorOf(s) != null) return false;
        if (d != null && !_public(s)) return false;
        if (!_seeHand(s)) return false;
        final card = _botCardHere(g, s, played);
        if (d != null) _op((d) => d.playOpen(s, d.positionOf(s, card.index)!));
        g.play(s, card);
        played.add(card);
        moves.add(Move(g.handNumber, s, card: card));
        _frame(FrameChange.played, s);
        return true;
      case Phase.handOver || Phase.gameOver:
        if (d != null) {
          for (var s = 0; s < seatCount; s++) {
            if (_owesAudit(s)) return false;
          }
          if (_openings.isNotEmpty) return false;
        }
        onHandOver?.call(g, d);
        if (g.phase == Phase.gameOver) {
          _state = TableState.finished;
          _owed.clear();
          return false;
        }
        g.nextHand();
        _startHand();
        _frame(FrameChange.nextHand);
        return true;
    }
  }

  /// Whether the engine can see [seat]'s hand, revealing it from the
  /// deal where this side can and the engine has not.
  bool _seeHand(int seat) {
    final g = game;
    if (g.knowsHand(seat)) return true;
    final d = _deal;
    if (d == null) return false;
    if (!openPassInto(d, g, seat)) return false;
    final cards = g.phase == Phase.playing ? d.handOf(seat) : d.dealtHandOf(seat);
    if (cards == null) return false;
    g.revealHand(seat, [for (final i in cards) Card.deck[i]]);
    return true;
  }

  /// The deal is done: the engine gets what this side can see.
  bool _dealt() {
    final d = _deal;
    if (d == null) return false;
    for (var s = 0; s < seatCount; s++) {
      if (!_progress.declared.contains(s) && !(_public(s) && d.hasDeclared(s))) return false;
    }
    if (_openings.isNotEmpty) return false;
    final lead = _leadPosition(d);
    final leader = lead == null ? null : d.holderOf(lead);
    if (leader == null) {
      // Every word says "not here", and nothing open holds the card:
      // somebody lied. The hand is opened by its audits and given up.
      if (!_progress.opening) {
        _progress.opening = true;
        trace?.call('hand ${game.handNumber}: nobody declared the lead card; opening it');
        return true;
      }
      for (var s = 0; s < seatCount; s++) {
        if (_owesAudit(s)) return false;
      }
      final liar = d.lied;
      trace?.call('hand ${game.handNumber} given up${liar == null ? '' : '; seat $liar said it held the lead card nowhere'}');
      // Removed in the hand it broke, so that the house holds the seat
      // from the next.
      if (liar != null) _remove(liar, Exit.lied);
      if (_state != TableState.playing) return false;
      game.abandonHand();
      _startHand();
      _frame(FrameChange.givenUp);
      return true;
    }
    game.declareLeader(leader);
    game.deal([
      for (var s = 0; s < seatCount; s++)
        switch (d.dealtHandOf(s)) {
          null => null,
          final cards => [for (final i in cards) Card.deck[i]],
        },
    ]);
    trace?.call('dealt hand ${game.handNumber}, seat $leader to lead');
    _frame(FrameChange.dealt);
    return true;
  }

  void _declareLead() {
    final d = _deal;
    final lead = d == null ? null : _leadPosition(d);
    if (lead != null && (game.phase == Phase.passing || game.phase == Phase.dealing)) game.declareLeader(d!.holderOf(lead));
  }

  /// Where the lead card was dealt, from what every side sees alike: a
  /// seat's word on it, or a hand open to everyone. Never from this
  /// side's own cards, which nobody else sees: a seat that said the card
  /// is nowhere while holding it would lead here, and nowhere else.
  int? _leadPosition(DealSession d) {
    for (final p in _progress.declaredAt.values) {
      if (p >= 0) return p;
    }
    for (var s = 0; s < seatCount; s++) {
      if (!_public(s)) continue;
      final cards = d.dealtHandOf(s);
      final at = cards?.indexOf(twoOfClubs.index) ?? -1;
      if (at >= 0) return s * (deckSize ~/ seatCount) + at;
    }
    return null;
  }

  /// Whether [seat] owes the hand its audit: a keyed seat somebody still
  /// takes the turns of, whose secret the log has not had yet.
  bool _owesAudit(int seat) => _keyed(seat) && actorOf(seat) != null && !_progress.audited.contains(seat);

  // ---- what is owed --------------------------------------------------------

  /// When each turn open now opened.
  final Map<TurnId, int> _since = {};

  /// Every turn open now, with when it opened: kept from before for a
  /// turn that was open already, now for one that just opened.
  void _owe() {
    final before = Map.of(_since);
    _since.clear();
    _owed.clear();
    if (_state != TableState.playing) return;
    for (final (seat, turn) in _turnsOpen()) {
      final actor = actorOf(seat);
      if (actor == null) continue;
      final since = before[turn] ?? _now;
      _since[turn] = since;
      _owed[seat] = Owed(turn: turn, seat: seat, actor: actor, since: since, allowance: _allowance(seat, turn));
    }
  }

  int _allowance(int seat, TurnId turn) {
    if (_holders[seat] is HumanSeat) return timing.bank.allowanceMs(turn, _banks[seat]);
    return (turn.isPass || turn.isPlay ? timing.botActsMs : timing.botDealsMs) + timing.houseGraceMs;
  }

  /// The turns open now that somebody has to say: every keyed seat's
  /// step of the deal's round, the shuffler's, each seat's pass, the
  /// seat on play, each audit owed.
  List<(int, TurnId)> _turnsOpen() {
    final g = game;
    final h = g.handNumber;
    final d = _deal;
    final out = <(int, TurnId)>[];
    switch (g.phase) {
      case Phase.dealing:
        if (d == null) return out;
        if (_progress.opening) {
          for (var s = 0; s < seatCount; s++) {
            if (_owesAudit(s)) out.add((s, TurnId.audit(h, s)));
          }
          return out;
        }
        final p = _progress;
        final keyedPending = [for (var s = 0; s < seatCount; s++) if (_keyed(s) && !_public(s) && !p.keys.contains(s)) s];
        if (keyedPending.isNotEmpty) return [for (final s in keyedPending) (s, TurnId.deal(h, 0, s))];
        for (var s = 0; s < seatCount; s++) {
          if (_keyed(s) && !_public(s)) {
            if (p.shuffled.contains(s)) continue;
            return [(s, TurnId.deal(h, 1, s))];
          }
          if (!d.hasShuffled(s)) return out; // everyone's to work out, and not yet
        }
        if (d.deck == null) return out;
        final tokens = [for (var s = 0; s < seatCount; s++) if (_keyed(s) && !_public(s) && !p.tokens.contains(s)) s];
        if (tokens.isNotEmpty) return [for (final s in tokens) (s, TurnId.deal(h, 2, s))];
        return [
          for (var s = 0; s < seatCount; s++)
            if (_keyed(s) && !_public(s) && !p.declared.contains(s)) (s, TurnId.deal(h, 3, s)),
        ];
      case Phase.passing:
        return [
          for (var s = 0; s < seatCount; s++)
            if (!g.hasPassed(s)) (s, TurnId.pass(h, s)),
        ];
      case Phase.playing:
        final s = g.currentSeat;
        if (s == null || g.trick.length == seatCount) return out;
        return [(s, TurnId.play(h, g.tricksPlayed * seatCount + g.trick.length))];
      case Phase.handOver || Phase.gameOver:
        if (d == null) return out;
        return [
          for (var s = 0; s < seatCount; s++)
            if (_owesAudit(s)) (s, TurnId.audit(h, s)),
        ];
    }
  }

  // ---- the moves ----------------------------------------------------------

  bool _takeDealStep(TableEvent ev, int seat, bool check) {
    final d = _deal;
    if (d == null) return false;
    final t = ev.turn;
    final b = Map<String, Object?>.from(ev.body);
    if (b['seat'] != seat) return false;
    if (t.isAudit) {
      if (ev.round != 4 || t.auditSeat != seat) return false;
      if (check && !d.verifyAudit(b)) return false;
      if (!_try((d) => d.acceptAudit(b, verified: true))) return false;
      _progress.audited.add(seat);
      return true;
    }
    if (!t.isDeal || t.dealRound != ev.round || t.dealSeat != seat) return false;
    if (check) {
      final ok = switch (ev.round) {
        0 => _custodiansFit(seat, b) && d.verifyKeys(b),
        1 => d.verifyShuffle(b),
        2 => d.verifyTokens(b),
        3 => d.verifyDeclaration(b),
        _ => false,
      };
      if (!ok) return false;
    }
    if (!_try((d) => _acceptStep(d, ev.round, b))) return false;
    final p = _progress;
    switch (ev.round) {
      case 0:
        p.keys.add(seat);
      case 1:
        p.shuffled.add(seat);
      case 2:
        p.tokens.add(seat);
      case 3:
        p.declared.add(seat);
        p.declaredAt[seat] = b['position'] as int;
    }
    return true;
  }

  /// Whether a seat's keys escrow where the table's do: a person's to
  /// the house, a bot seat's to nobody. Keys escrowed elsewhere would
  /// leave a hand nobody could open when its person went.
  bool _custodiansFit(int seat, Map<String, Object?> b) {
    final custodians = [for (final k in b['custodians'] as List) k as String];
    if (_holders[seat] is HumanSeat) return custodians.length == 1 && custodians.single == _spec!.house;
    return custodians.isEmpty;
  }

  static bool _acceptStep(DealSession d, int round, Map<String, Object?> b) => switch (round) {
        0 => d.acceptKeys(b, verified: true),
        1 => d.acceptShuffle(b, verified: true),
        2 => d.acceptTokens(b, verified: true),
        3 => d.acceptDeclaration(b, verified: true),
        _ => false,
      };

  bool _takePass(TableEvent ev, int seat, bool check) {
    final g = game;
    if (g.phase != Phase.passing || g.hasPassed(seat)) return false;
    final d = _deal;
    final to = (seat + g.passDirection.seatOffset) % seatCount;
    try {
      if (d != null) {
        final b = Map<String, Object?>.from(ev.body);
        if ((b['positions'] as List).length != passSize || b['from'] != seat || b['to'] != to) return false;
        if (check && !d.verifyPass(b)) return false;
        if (!_try((d) => d.acceptPass(b, verified: true))) return false;
        final positions = [for (final p in b['positions'] as List) p as int];
        final cards = <Card>[];
        for (final p in positions) {
          final c = d.openedCardAt(p);
          if (c == null) break;
          cards.add(Card.deck[c]);
        }
        _declareLead();
        final seen = cards.length == positions.length ? cards : null;
        g.setPass(seat, seen);
        moves.add(Move(g.handNumber, seat, passed: seen, hidden: seen == null));
        _frame(FrameChange.passed, seat);
        return true;
      }
      final cards = [for (final c in ev.body['cards'] as List) Card.parse(c as String)];
      if (cards.length != passSize || cards.toSet().length != passSize || !cards.every(g.handOf(seat).contains)) return false;
      g.setPass(seat, cards);
      moves.add(Move(g.handNumber, seat, passed: cards));
      _frame(FrameChange.passed, seat);
      return true;
    } catch (e) {
      trace?.call('a pass that does not read: $e');
      return false;
    }
  }

  bool _takePlay(TableEvent ev, int seat, bool check) {
    final g = game;
    if (g.phase != Phase.playing || g.currentSeat != seat) return false;
    try {
      final card = Card.parse(ev.body['card'] as String);
      final d = _deal;
      if (d != null) {
        final b = Map<String, Object?>.from(ev.body);
        if (check && d.verifyPlay(seat, b) != card.index) return false;
        if (!g.allows(seat, card)) return false;
        if (!_try((d) => d.acceptPlay(seat, b, verified: true) == card.index)) return false;
      } else if (!g.legalPlaysFor(seat).contains(card)) {
        return false;
      }
      g.play(seat, card);
      played.add(card);
      moves.add(Move(g.handNumber, seat, card: card));
      _frame(FrameChange.played, seat);
      return true;
    } catch (e) {
      trace?.call('a play that does not read: $e');
      return false;
    }
  }

  void _takeRelease(TableEvent ev) {
    final d = _deal;
    if (d == null || ev.hand != game.handNumber) return;
    final b = Map<String, Object?>.from(ev.body);
    if (b['holder'] != ev.author) return;
    final about = ev.about;
    if (about < 0 || about >= seatCount || !_openings.containsKey(about)) return;
    if (_try((d) => d.acceptRelease(b))) taken.add(ev);
  }

  /// The card [persona], a bot at [seat], plays where [g] stands, with
  /// [played] the cards played this hand before it.
  static Card botCard(HeartsGame g, int seat, Set<Card> played, Persona persona) {
    final view = BotView(
      seat: seat,
      hand: g.handOf(seat),
      trick: g.trick,
      played: played,
      heartsBroken: g.heartsBroken,
      isFirstTrick: g.isFirstTrick,
      taken: g.taken,
    );
    return Bot(persona: persona).chooseCard(view, g.legalPlaysFor(seat));
  }

  Card _botCardHere(HeartsGame g, int seat, Set<Card> played) => botCard(g, seat, played, (_holders[seat] as BotSeat).persona);

  /// What every side sees of the table now, alike: whose turns are open
  /// and since when, who holds the seats and who has gone, the hand and
  /// its tricks, the clocks. Nothing any one side holds alone is in it.
  String settledView() => jsonEncode({
        'state': _state.name,
        if (_spec != null) ...{
          'hand': game.handNumber,
          'phase': game.phase.name,
          'holders': [for (final h in _holders) h is HumanSeat ? h.key : 'bot'],
          'removals': {for (final e in _removals.entries) '${e.key}': '${e.value.exit.name}@${e.value.n}'},
          'owed': [for (final o in _owed.values) '${o.seat} ${o.turn} ${o.actor} ${o.since} ${o.allowance}'],
          'openings': {for (final e in _openings.entries) '${e.key}': e.value},
          'paused': _pausedAt,
          'banks': _banks,
          'totals': game.totals,
          'trick': [for (final p in game.trick) '${p.seat}:${p.card.code}'],
          'tricks': game.tricksPlayed,
          'played': played.length,
          'end': _endN,
        },
      });

  @override
  String toString() => 'TableRules($tableId, ${_state.name}, #${log.length}, owed ${_owed.values})';

  /// A line for a trace: where the table stands.
  String describe() => jsonEncode({
        'n': log.length,
        'state': _state.name,
        if (_game != null) 'hand': game.handNumber,
        if (_game != null) 'phase': game.phase.name,
        'owed': [for (final o in _owed.values) '$o'],
        'openings': {for (final e in _openings.entries) '${e.key}': e.value},
        'removals': {for (final e in _removals.entries) '${e.key}': e.value.exit.name},
      });
}

/// What the log has taken of one hand's deal, by seat.
class _Progress {
  final Set<int> keys = {};
  final Set<int> shuffled = {};
  final Set<int> tokens = {};
  final Set<int> declared = {};

  /// Each seat's word on where the lead card is: a position of its own,
  /// or -1 for nowhere.
  final Map<int, int> declaredAt = {};
  final Set<int> audited = {};

  /// The lead card's holder said it held it nowhere: the hand is opened
  /// by its audits and given up.
  bool opening = false;
}

/// A pass or a play, as the table took it.
class Move {
  const Move(this.hand, this.seat, {this.card, this.passed, this.hidden = false});
  final int hand;
  final int seat;

  /// The card played, for a play.
  final Card? card;

  /// The cards passed, for a pass this side can see.
  final List<Card>? passed;

  /// A pass whose cards this side cannot see.
  final bool hidden;

  bool get isPass => card == null;
}

/// What changed in a [Frame].
enum FrameChange {
  /// The hand's cards dealt: at a sealed table, as this side sees them.
  dealt,

  /// [Frame.seat]'s pass taken.
  passed,

  /// [Frame.seat]'s card played.
  played,

  /// A finished trick swept to whoever took it.
  collected,

  /// The next hand begun, after one scored.
  nextHand,

  /// A hand given up where it stood, and the next one begun in its
  /// place: nobody could lead it, or a departed hand could not be
  /// opened.
  givenUp,

  /// [Frame.seat] held by somebody else: a person gone, a bot in their
  /// place.
  seat,
}

/// The table just after one change a person could see ([TableRules.onFrame]).
class Frame {
  const Frame(this.change, {required this.game, required this.holders, required this.played, this.seat});
  final FrameChange change;

  /// The game as it stood then: a copy, which the table goes on without
  /// (HeartsGame.lookahead).
  final HeartsGame game;

  /// Who held each seat then.
  final List<SeatHolder> holders;

  /// The cards played in the hand by then.
  final Set<Card> played;

  /// The seat that passed, played or changed hands.
  final int? seat;

  @override
  String toString() => 'Frame(${change.name}${seat == null ? '' : ' $seat'}, hand ${game.handNumber} ${game.phase.name})';
}
