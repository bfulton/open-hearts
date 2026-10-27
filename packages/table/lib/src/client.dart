/// One side at a live table: a person's device, or the house playing a
/// bot seat or following the table (docs/explanation/live-play.md).
///
/// The table is the referee's log and the rules applied to it
/// (rules.dart). A client reads the log through its line
/// (referee_line.dart), applies it, and says what its seat owes when it
/// owes it: a person's deal steps and audit by themselves, their pass
/// and play when the player chooses; the house its bot seat's every
/// move. It says its piece of a departed person's secret when the table
/// needs it, and asks the referee for the time when a deadline it can
/// see is due. That is all: nothing here votes, repeats or catches
/// anybody up.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:deal/deal.dart';
import 'package:engine/engine.dart';

import 'clock.dart';
import 'conduct.dart';
import 'events.dart';
import 'journal.dart';
import 'log.dart';
import 'referee_line.dart';
import 'rules.dart';
import 'signing.dart';
import 'spec.dart';

/// Which side this is.
enum Role {
  /// A person in their seat.
  person,

  /// The house, playing the bot seat [TableClient.seat] whenever it holds
  /// it.
  houseSeat,

  /// The house following the table: its pieces of the escrow said when a
  /// person goes, its word on the result said at the end.
  houseFollower,
}

class TableClient {
  TableClient({
    required this.tableId,
    required this.signer,
    required this.line,
    required this.clock,
    this.role = Role.person,
    this.spec,
    this.seat,
    this.crypto,
    this.dealWorker,
    this.journal,
    this.houseSecret,
    this.botThinkMs,
    this.conduct = const SeatConduct(),
    Random? random,
    this.trace,
  }) : _random = random ?? Random.secure() {
    if (role == Role.person && spec == null) throw ArgumentError('a person sits at the table they were seated at');
    if (role == Role.houseSeat && (seat == null || houseSecret == null)) throw ArgumentError('the house plays a seat with a secret of its own');
    rules = TableRules(
      tableId: tableId,
      crypto: crypto,
      myKey: role == Role.person || role == Role.houseSeat || role == Role.houseFollower ? signer.publicKey : null,
      mySeat: role == Role.person ? spec!.seatOf(signer.publicKey) : (role == Role.houseSeat ? seat : null),
      wrap: signer.sharedSecretWith,
      secretFor: _secretFor,
      keepSecret: role == Role.person ? (hand, secret) => journal?.keep(hand, secret) : null,
      worker: dealWorker,
      random: _random,
      trace: _trace,
    )..onChange = _changed;
  }

  final String tableId;
  final Signer signer;
  final RefereeLine line;
  final Clock clock;
  final Role role;

  /// The spec this side was seated with: a person's, from the lobby. The
  /// log's start has to say the same.
  final TableSpec? spec;

  /// The house's bot seat, for [Role.houseSeat].
  final int? seat;

  final DealCrypto? crypto;
  final DealWorker? dealWorker;

  /// What a person's device keeps of the table across a reload: each
  /// hand's deal secret (journal.dart).
  final TableJournal? journal;

  /// The house's own secret, the bot seats' deal secrets are made from.
  final Uint8List? houseSecret;

  /// For the house's seat: how long its bot thinks over a card, drawn
  /// for its persona each time (house.dart, pace), or null for not at
  /// all. The card is said after it, so the log has the bot's rhythm in
  /// its own times: a screen shows each card as it lands, and the next
  /// person's clock starts when they can see that it is their turn.
  final int Function(Persona persona)? botThinkMs;

  /// What this seat says where it could say something else: the
  /// honest conduct everywhere but the simulator.
  final SeatConduct conduct;

  final Random _random;
  final void Function(String line)? trace;

  late final TableRules rules;

  final _changes = StreamController<void>.broadcast(sync: true);

  /// Told after every change of the table, or of this side's line.
  Stream<void> get changes => _changes.stream;

  // ---- reading the table ------------------------------------------------

  /// The table's spec: the log's, once it has started; the seated one's
  /// until then.
  TableSpec? get tableSpec => rules.spec ?? spec;

  /// The game, as the log has it; before the log's start, for a person,
  /// the game their seated spec starts — the same one, before anything
  /// is in it.
  HeartsGame get game {
    if (started) return rules.game;
    final s = spec;
    if (s == null) return rules.game;
    return _before ??= HeartsGame(seed: s.seed, sealed: s.sealed, target: s.target);
  }

  HeartsGame? _before;
  bool get started => rules.spec != null;
  /// Who holds each seat: as the log has it, or as the person was
  /// seated before its start.
  List<SeatHolder> get holders => started ? rules.holders : List.unmodifiable(spec?.seats ?? const <SeatHolder>[]);

  /// This person's seat, where they sat down.
  int? get mySeat => role == Role.person ? spec!.seatOf(signer.publicKey) : seat;

  /// Whether this person still holds their seat.
  bool get amSeated {
    final s = mySeat;
    if (role != Role.person || s == null || !started) return role == Role.person && s != null && !_left;
    final h = rules.holders[s];
    return h is HumanSeat && h.key == signer.publicKey;
  }

  /// The game is over for good: finished, ended or failed.
  bool get done => rules.over;
  TableState get state => rules.state;

  /// The deal of the current hand and of any hand so far, at a sealed
  /// table.
  DealSession? get deal => rules.deal;
  DealSession? dealOf(int hand) => rules.dealOf(hand);

  /// What this side's seat owes now, if anything.
  Owed? get myTurn {
    final s = mySeat;
    if (s == null || !started) return null;
    final o = rules.owed[s];
    return o != null && o.actor == signer.publicKey ? o : null;
  }

  bool get awaitingMyPass => _caughtUp && role == Role.person && (myTurn?.turn.isPass ?? false) && !_said.contains(myTurn!.turn);
  bool get awaitingMyPlay => _caughtUp && role == Role.person && (myTurn?.turn.isPlay ?? false) && !_said.contains(myTurn!.turn);

  /// Whether this side has the log as far as the referee has it, and has
  /// taken all of it: until it has, a turn open here may be answered
  /// further on, by this side before a reload, and nothing is said.
  bool get _caughtUp => line.up && rules.waitingToTake == 0;

  /// The same, for a view of the table: what came while this side was
  /// catching up is shown at once, not at a person's pace.
  bool get caughtUp => _caughtUp;

  /// The referee's time now, as near as this side can tell: the time of
  /// the last entry, and how long ago that came.
  int get refereeNow => _lastT + (clock.nowMs - _lastAt);
  int _lastT = 0;
  int _lastAt = 0;

  /// How long [seat]'s person has left at their pass or play, once the
  /// grace is spent: their bank, counting down. Null within the grace,
  /// and for every other turn — the deal's, which a device answers by
  /// itself, and the house's. Stopped where every clock is, while a
  /// departed hand is opened.
  int? clockMs(int seat) {
    final o = rules.owed[seat];
    if (o == null || !(o.turn.isPass || o.turn.isPlay) || rules.holders[seat] is! HumanSeat) return null;
    final now = min(refereeNow, rules.pausedAt ?? refereeNow);
    if (now - o.since < rules.timing.bank.graceOf(o.turn)) return null;
    return max(0, o.deadline - now);
  }

  /// Whether this side's line to the referee is down.
  bool get lineDown => !line.up;

  /// Why this device cannot deal, once its worker failed for good.
  String? get cannotDeal => rules.cannotDeal;

  // ---- starting and stopping -------------------------------------------

  bool _opened = false;
  bool _closed = false;
  bool _left = false;

  /// Whether this person has said they are leaving.
  bool get left => _left;

  void start() {
    if (_opened) return;
    _opened = true;
    line.onUp = (_) => _changed();
    line.open(0, _onEntry);
    // A person's device starts the log, if nobody has yet: the first
    // start the referee is sent is the table's, and the rest are not
    // taken.
    if (role == Role.person) _send(EventKind.start, {'spec': spec!.toJson()});
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _tickTimer?.call();
    _thinkTimer?.call();
    line.close();
    // Closed a moment later: this may be called from a listener, while
    // the stream is still telling the others.
    clock.schedule(0, _changes.close);
  }

  void _onEntry(LogEntry e) {
    if (_closed) return;
    _lastT = e.t;
    _lastAt = clock.nowMs;
    rules.feed(e);
  }

  // ---- what this side says ----------------------------------------------

  /// The turns this side has said something for.
  final Set<TurnId> _said = {};

  /// The departed seats whose piece this side has said, by hand.
  final Set<(int, int)> _released = {};
  bool _resulted = false;

  void _changed() {
    if (_closed) return;
    if (started && role == Role.person && jsonEncode(rules.spec!.toJson()) != jsonEncode(spec!.toJson())) {
      _trace('the log started a table other than the one seated');
    }
    if (rules.cannotDeal != null && role == Role.person && amSeated && !_left) leave();
    _act();
    _release();
    _sayResult();
    _armTick();
    _notify();
  }

  bool _notifying = false;
  bool _notifyAgain = false;

  /// Tells the listeners, once a listener's own change is in: one that
  /// acts on a change (a person's autopilot, the simulator's people)
  /// changes the table again while it is being told.
  void _notify() {
    if (_closed) return;
    if (_notifying) {
      _notifyAgain = true;
      return;
    }
    _notifying = true;
    try {
      do {
        _notifyAgain = false;
        _changes.add(null);
      } while (_notifyAgain && !_closed);
    } finally {
      _notifying = false;
    }
  }

  /// This seat's move, where it owes one this side makes by itself.
  void _act() {
    if (_left || !started || rules.over || !_caughtUp) return;
    final o = myTurn;
    if (o == null || _said.contains(o.turn)) return;
    final d = rules.deal;
    final t = o.turn;
    final s = o.seat;
    final body = <String, Object?>{'hand': t.hand, 'turn': t.index, 'seat': s};
    if (t.isDeal || t.isAudit) {
      if (d == null || d.mySeat != s) return;
      final round = t.isAudit ? 4 : t.dealRound;
      Map<String, Object?>? m;
      switch (round) {
        case 0:
          m = d.myKeys();
        case 1:
          if (d.nextShuffler != s || !_workedOut(d.workToMake(1))) return;
          m = d.myShuffle();
        case 2:
          if (d.deck == null || !_workedOut(d.workToMake(2))) return;
          m = d.myTokens();
        case 3:
          final honest = d.myDeclaration();
          m = honest == null ? null : conduct.declaration(honest);
        case 4:
          m = d.myAudit();
      }
      if (m == null) return;
      _say(t, EventKind.deal, {...body, 'round': round, ...m});
      return;
    }
    if (role != Role.houseSeat) return; // a person's pass and play are theirs to choose
    final g = rules.game;
    if (!g.knowsHand(s)) return;
    final persona = (rules.holders[s] as BotSeat).persona;
    final bot = Bot(persona: persona);
    if (t.isPass) {
      _sayPass(s, bot.choosePass(g.handOf(s)));
    } else if (t.isPlay) {
      final think = botThinkMs?.call(persona) ?? 0;
      if (think > 0 && _thought != t) {
        if (_thinking == t) return;
        _thinking = t;
        _thinkTimer = clock.schedule(think, () {
          _thinkTimer = null;
          _thinking = null;
          _thought = t;
          _act();
        });
        return;
      }
      _sayPlay(s, TableRules.botCard(g, s, rules.played, holders: rules.holders));
    }
  }

  /// The house's seat thinking over the card of [_thinking], until
  /// [_thinkTimer] fires; and the turn it last thought over, whose card
  /// it says when next asked.
  TurnId? _thinking;
  TurnId? _thought;
  Cancel? _thinkTimer;

  /// A person's pass, chosen.
  void pass(List<Card> cards) {
    if (!awaitingMyPass) return;
    _sayPass(mySeat!, cards);
  }

  /// A person's play, chosen.
  void play(Card card) {
    if (!awaitingMyPlay) return;
    if (!rules.game.legalPlaysFor(mySeat!).contains(card)) return;
    _sayPlay(mySeat!, card);
  }

  void _sayPass(int seat, List<Card> cards) {
    final o = myTurn;
    if (o == null || !o.turn.isPass) return;
    final body = <String, Object?>{'hand': o.turn.hand, 'turn': o.turn.index, 'seat': seat};
    final d = rules.deal;
    if (d != null) {
      // The cards stay hidden: the positions move, and the tokens that
      // open them go to the receiver alone.
      final positions = [for (final c in cards) d.positionOf(seat, c.index)];
      if (positions.any((p) => p == null)) return;
      final to = (seat + rules.game.passDirection.seatOffset) % seatCount;
      final m = d.passMessage(to, [for (final p in positions) p!]);
      if (m == null) return;
      final sealed = m['sealed'];
      if (sealed is List<String>) m['sealed'] = conduct.sealedPass(sealed, _random);
      body.addAll(m);
    } else {
      body['cards'] = [for (final c in cards) c.code];
    }
    _say(o.turn, EventKind.pass, body);
  }

  void _sayPlay(int seat, Card card) {
    final o = myTurn;
    if (o == null || !o.turn.isPlay) return;
    final body = <String, Object?>{'hand': o.turn.hand, 'turn': o.turn.index, 'seat': seat, 'card': card.code};
    final d = rules.deal;
    if (d != null) {
      final p = d.positionOf(seat, card.index);
      if (p == null) return;
      final m = d.playToken(p);
      if (m == null) return;
      body.addAll(m);
    }
    _say(o.turn, EventKind.play, body);
  }

  /// This person leaving: their own word, which removes them where the
  /// log takes it.
  void leave() {
    if (role != Role.person || _left) return;
    _left = true;
    _send(EventKind.leave, {'seat': mySeat!});
    _notify();
  }

  void _say(TurnId turn, EventKind kind, Map<String, Object?> body) {
    _said.add(turn);
    _send(kind, body);
  }

  void _send(EventKind kind, Map<String, Object?> body) {
    final e = TableEvent.sign(signer, table: tableId, kind: kind, body: body);
    rules.made(e);
    line.send(e);
  }

  /// This side's piece of each departed person's secret the table is
  /// waiting on, said once: in the open, since the seat is played by
  /// everyone from here (docs/explanation/fair-deal.md).
  void _release() {
    if (!started || rules.over || !_caughtUp || (role == Role.person && (!amSeated || _left)) || role == Role.houseSeat) return;
    final d = rules.deal;
    if (d == null || !conduct.releases) return;
    for (final seat in rules.openings.keys) {
      final key = (rules.game.handNumber, seat);
      if (_released.contains(key)) continue;
      final m = d.releaseShare(seat, inTheOpen: true);
      if (m == null) continue;
      _released.add(key);
      _send(EventKind.release, {'hand': rules.game.handNumber, 'about': seat, ...m});
    }
  }

  /// The house's word on how the game came out, once it is over: the
  /// log as it stood then, and the totals.
  void _sayResult() {
    if (role != Role.houseFollower || _resulted || !rules.over || rules.endN == null || !_caughtUp) return;
    if (rules.state == TableState.failed && !started) return;
    _resulted = true;
    _send(EventKind.result, {
      'n': rules.endN!,
      'hash': rules.endHash!,
      'state': rules.state.name,
      'totals': started ? rules.game.totals : const [0, 0, 0, 0],
    });
  }

  // ---- the deal's slow calls ----------------------------------------------

  final Set<String> _working = {};

  /// Whether this side's own step's slow calls have their answers here;
  /// those that do not are sent to the worker, and the step made when
  /// they come back.
  bool _workedOut(List<DealJob> jobs) {
    final w = dealWorker;
    final c = rules.deal?.crypto;
    if (w == null || c is! PreparedDeal) return true;
    var all = true;
    for (final job in jobs) {
      if (c.has(job)) continue;
      all = false;
      if (!_working.add(job.key)) continue;
      w.run(job, done: (answer) {
        _working.remove(job.key);
        c.put(job, answer);
        _act();
      }, failed: (why) => _trace('cannot make a step of the deal: $why'));
    }
    return all;
  }

  // ---- the time ----------------------------------------------------------

  Cancel? _tickTimer;
  int _tickFor = -1;

  /// Asks the referee for the time when the next deadline this side can
  /// see is due, so that every side sees it pass: a turn's, a closed
  /// connection's silence at its turn, an opening's.
  void _armTick() {
    if (!started || rules.over) {
      _tickTimer?.call();
      _tickTimer = null;
      return;
    }
    int? due;
    void consider(int at) => due = due == null ? at : min(due!, at);
    // No turn's clock runs while a departed hand is opened.
    for (final o in rules.paused ? const <Owed>[] : rules.owed.values) {
      consider(o.deadline);
      final since = rules.down[o.actor];
      if (since != null) consider(since + rules.timing.silenceMs);
    }
    for (final at in rules.openings.values) {
      consider(at + rules.timing.bank.fixedMs);
    }
    if (due == null || due == _tickFor) return;
    _tickTimer?.call();
    _tickFor = due!;
    // A moment past it, so that the tick is after it.
    final wait = max(0, due! + 1 - refereeNow);
    _tickTimer = clock.schedule(wait, _tickNow);
  }

  void _tickNow() {
    _tickTimer = null;
    if (_closed || rules.over) return;
    line.tick();
    // Asked again in a second while nothing has moved the table on.
    final asked = _tickFor;
    _tickTimer = clock.schedule(1000, () {
      if (_tickFor == asked) _tickNow();
    });
  }

  // ---- the house's secrets ---------------------------------------------

  /// The deal secret this side's seat uses at [hand]: the house's made
  /// from its own secret, a person's from the journal or drawn.
  Uint8List? _secretFor(int hand) {
    final hs = houseSecret;
    if (role == Role.houseSeat && hs != null) {
      return Uint8List.fromList(sha256.convert([...hs, ...utf8.encode('|bot|$tableId|$hand|$seat')]).bytes);
    }
    return journal?.secretFor(hand);
  }

  void _trace(String line) => trace?.call(line);
}
