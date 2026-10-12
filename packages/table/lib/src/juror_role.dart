/// This side as a juror (docs/explanation/live-play.md): the hands it
/// was summoned to, the appeals it hears, and the verdicts it gives.
///
/// A juror sits at no seat. It follows a table it was summoned to, and
/// rules on a turn the people there cannot settle among themselves.
/// What it holds of its own is here. What it reads of the table it
/// rules on, it reads through [JurorTable], which the table's client
/// gives it; it changes nothing there but by saying something.
library;

import 'clock.dart';
import 'events.dart';
import 'signing.dart';
import 'spec.dart';

/// One turn's votes, as the table holds them: what a juror rules on.
abstract interface class TurnVotes {
  bool get settled;

  /// The seat's move, if one has been said.
  TableEvent? get action;

  /// At a bot seat, the moves said for it other than [action], by id.
  Map<String, TableEvent> get rivals;

  /// Claims that the seat is out.
  List<TableEvent> get boots;

  /// Every witness heard for the turn.
  List<TableEvent> get witnessEvents;

  Set<PublicKey> get forAction;
  Set<PublicKey> get forRemoval;
  Set<PublicKey> get forEnd;
}

/// What a juror reads of the table it serves, and how it says what it
/// rules.
abstract interface class JurorTable {
  int get handNumber;

  /// The turn's votes, or null for a turn this side has not reached.
  TurnVotes? votesAt(TurnId turn);

  /// The seat [turn] is the turn of.
  int seatAt(TurnId turn);

  SeatHolder holderOf(int seat);

  /// The jury drawn for [hand] that is in force, foreman first; empty
  /// when none is.
  List<PublicKey> juryInForce(int hand);

  /// The juror holding bot [seat] at [hand], or null.
  PublicKey? botHolder(int hand, int seat);

  /// Jurors of [hand] heard from lately, or drawn too recently to
  /// have been.
  Set<PublicKey> liveJurors(int hand);

  /// Whether juror [key] has been heard within the table's juror
  /// silence.
  bool jurorRecent(PublicKey key);

  /// Who a majority at [turn] is of, and how many make one.
  Set<PublicKey> participantsAt(TurnId turn);
  int majority(Set<PublicKey> of);

  /// Whether [key] has been silent past the table's silence.
  bool silent(PublicKey key);

  /// When [key] was last heard, or null.
  int? lastHeard(PublicKey key);

  /// Who has backed [key]'s leave, and whether [key]'s own leave is
  /// heard here.
  Set<PublicKey> leaveBackersOf(PublicKey key);
  bool hasLeft(PublicKey key);

  /// Whether bot [seat]'s holder is out of time on its turn.
  bool outOfTime(int seat);

  /// Whether no move for the bot seat at [turn] can still carry among
  /// [of].
  bool rivalsDeadlocked(TurnId turn, Set<PublicKey> of);

  /// Says an event of this side's, as the table says one.
  void emit(EventKind kind, Map<String, Object?> body, {bool everywhere});

  /// Sends [json] on as it is, by every path when [everywhere].
  void broadcast(Map<String, Object?> json, {bool everywhere});

  void trace(String line);
}

class JurorRole {
  JurorRole({required this.signer, required this.tableId, required this.clock, required this.table});

  final Signer signer;
  final String tableId;
  final Clock clock;
  final JurorTable table;

  // The hands this client serves, each with the jury it was summoned
  // into, foreman first; the appeals heard; the verdicts given.
  final Map<int, List<PublicKey>> _serving = {};

  /// The first hand this client was summoned to. Everything before it
  /// is history the client reads and has no part in: any seat this key
  /// held earlier was held by a client that has since been let go of,
  /// with secrets this one never had ([before]); and the duty starts no
  /// client on a summons to a hand that one had reached
  /// (juror_duty.dart).
  int? _summonedFrom;

  final Map<TurnId, int> _appealSeenAt = {};

  /// When each appeal was last heard here. An appeal stands while the
  /// people say it ([appealStandsMs]); one gone unheard that long is a
  /// table this juror has lost, or one that no longer asks.
  final Map<TurnId, int> _appealHeardAt = {};
  final Map<TurnId, int> _verdictAt = {};
  final Map<TurnId, int> _waitSaidAt = {};

  /// The first jury of each hand as a summons gave it, where one has
  /// said so. The event carries the same list and is the authority;
  /// this is the same thing arriving sooner, and a juror needs it
  /// sooner: one that does not know it holds a seat cannot make that
  /// seat's keys, and the hand stops at them.
  final Map<int, ({String juryId, List<PublicKey> jurors})> _firstSummons = {};

  /// When this side was first summoned to each hand: a summons is the
  /// jury arriving by another road, and a juror named in it is live
  /// from then as one named in a jury event would be
  /// ([JurorTable.liveJurors]).
  final Map<int, int> _servingSince = {};

  /// The hand in which this juror last heard an appeal.
  int _carryingHand = -1;

  /// How long an appeal stands once last heard: three of the people's,
  /// said every ten seconds while a turn is stuck. A juror rules by the
  /// seat's presence to it, and a juror that has lost the table hears
  /// every seat fall silent and cannot tell that from its own silence.
  /// Ruling on an appeal heard minutes before, it put the seat out on
  /// its own record alone, at a turn the table had settled by the
  /// seat's own card (`test/juror_cut_off_test.dart`). So it carries
  /// and rules only while it still hears the appeal; it takes it up
  /// again as soon as it does.
  static const appealStandsMs = 30000;

  final Map<TurnId, int> _relayedAt = {};

  /// Summoned into the jury of [hand], [jurors] being the draw, foreman
  /// first.
  void summon(int hand, List<PublicKey> jurors, {String? juryId, bool first = false}) {
    _serving[hand] = jurors;
    _servingSince.putIfAbsent(hand, () => clock.nowMs);
    _summonedFrom ??= hand;
    // A summons into the hand's *first* jury is the draw a bot seat's
    // holder is read from, arriving by the shorter road: kept apart
    // from the rest so that a redraw, which names the jury as it
    // stands now, never moves a seat (TableClient.botHolders).
    if (first && juryId != null) _firstSummons.putIfAbsent(hand, () => (juryId: juryId, jurors: jurors));
  }

  /// Whether [hand] was over before the first summons that brought
  /// this side here: history it reads and has no part in.
  ///
  /// A juror's client is let go of once the table has moved past every
  /// hand it serves, and a later summons starts a new one, which reads
  /// the record from the first hand. The key is the same, so the record
  /// names it as the holder of every bot seat its earlier client held;
  /// the secrets are not, and never were. Acting on that name, a juror
  /// drawn again would make fresh keys for a seat its earlier client
  /// held, take them over the ones on the record — a session keeps its
  /// own seat's keys and no other — and could verify nothing the table
  /// shuffled from them.
  ///
  /// So an earlier hand is one where this side holds nothing and makes
  /// no move for any seat: it follows the record there as a player
  /// does, and says nothing about it. A summons to an earlier hand
  /// arriving after the first does not move the line back. The table
  /// was past that hand when it drew the jury that brought this
  /// client, and the key may have served it in a client before this
  /// one, heard of from the jury rather than the summons.
  bool before(int hand) {
    final from = _summonedFrom;
    return from != null && hand < from;
  }

  /// Whether this side was summoned to any hand, and which.
  bool get summoned => _serving.isNotEmpty;
  Iterable<int> get hands => _serving.keys;

  /// The jury this side was summoned into for [hand], or null.
  List<PublicKey>? summonedInto(int hand) => _serving[hand];

  /// Whether it serves [hand] or one after it.
  bool servesFrom(int hand) => _serving.keys.any((h) => h >= hand);

  ({String juryId, List<PublicKey> jurors})? firstSummons(int hand) => _firstSummons[hand];

  /// When this side was first summoned to [hand], or null.
  int? servingSince(int hand) => _servingSince[hand];

  /// The appeals this side has heard and not yet seen settled.
  Iterable<TurnId> get appeals => _appealSeenAt.keys;

  /// A juror that stops: no more heartbeats, no more verdicts. The
  /// table notices the silence and draws another.
  void stop() {
    _serving.clear();
    _appealSeenAt.clear();
    _appealHeardAt.clear();
  }

  /// The order this side answers appeals in at [hand]: the jury it was
  /// summoned into most recently by then, or the one in force.
  List<PublicKey> orderFor(int hand) {
    var latest = -1;
    for (final h in _serving.keys) {
      if (h <= hand && h > latest) latest = h;
    }
    if (latest >= 0) return _serving[latest]!;
    return table.juryInForce(hand);
  }

  /// An appeal by one of the people, to a jury this side sits on.
  void heardAppeal(TableEvent event) {
    if (!orderFor(event.hand).contains(signer.publicKey)) return;
    _appealSeenAt.putIfAbsent(event.turn, () => clock.nowMs);
    _appealHeardAt[event.turn] = clock.nowMs;
    _carryingHand = event.hand;
    judgeAppeals();
  }

  /// An appeal said again by one of the people: the same appeal, and
  /// it still stands ([appealStandsMs]).
  void heardAgain(TurnId turn) {
    if (_appealSeenAt.containsKey(turn)) _appealHeardAt[turn] = clock.nowMs;
  }

  /// A juror hears both sides of a table cut in two. From the first
  /// appeal of a hand to the end of it, the first juror in the draw
  /// still heard from says again, at once, everything it hears for a
  /// turn not yet settled, so the votes cross the cut and the table
  /// runs at its own pace rather than an appeal's. One juror carries,
  /// not four: a shared relay sees each event twice, not five times.
  void relayIfAppealed(TableEvent event) {
    final hand = table.handNumber;
    if (_carryingHand != hand) return;
    final order = orderFor(hand);
    final carrier = order.where((j) => j == signer.publicKey || table.jurorRecent(j)).firstOrNull;
    if (carrier != signer.publicKey) return;
    if (table.votesAt(event.turn)?.settled == true) return;
    table.broadcast(event.toJson());
  }

  void judgeAppeals() {
    for (final turn in List.of(_appealSeenAt.keys)) {
      final race = table.votesAt(turn);
      if (race == null) continue; // still catching up to it
      if (race.settled) {
        _appealSeenAt.remove(turn);
        _appealHeardAt.remove(turn);
        _relayedAt.remove(turn);
        continue;
      }
      final heardAt = _appealHeardAt[turn];
      if (heardAt == null || clock.nowMs - heardAt >= appealStandsMs) continue;
      // What this juror holds for the turn, said again every five
      // seconds while the appeal stands: a table cut in two has its
      // votes on both sides, and the juror is the one who hears both.
      final last = _relayedAt[turn];
      if (last == null || clock.nowMs - last >= 5000) {
        _relayedAt[turn] = clock.nowMs;
        // By every path: the two sides of a cut table may read
        // different relays, and the juror is here to be heard by both.
        if (race.action != null) table.broadcast(race.action!.toJson(), everywhere: true);
        for (final b in race.boots) {
          table.broadcast(b.toJson(), everywhere: true);
        }
        for (final w in race.witnessEvents) {
          table.broadcast(w.toJson(), everywhere: true);
        }
      }
      _judge(turn, race);
    }
  }

  /// The rule. A juror rules only when nobody who can still vote, as
  /// far as it can hear, could carry either side — votes that may yet
  /// come are carried, not overruled — and then by the seat's presence
  /// to it: heard and acted, the action stands; silent, the removal.
  /// Heard and not yet acted is nobody's to decide; the seat's own
  /// clock runs. The foreman rules first; each juror behind waits five
  /// seconds more.
  void _judge(TurnId turn, TurnVotes race) {
    final order = orderFor(turn.hand);
    final place = order.indexOf(signer.publicKey);
    if (place < 0 || clock.nowMs - _appealSeenAt[turn]! < place * 5000) return;
    final last = _verdictAt[turn];
    if (last != null && clock.nowMs - last < 10000) return;
    final seat = table.seatAt(turn);
    final holder = table.holderOf(seat);
    if (holder is! HumanSeat && (race.boots.isNotEmpty || race.rivals.isEmpty)) {
      // A held seat's juror's move against the escrow, neither able to
      // carry — or its move alone, short of a majority because the only
      // other person at the table has gone silent: ruled as a person's
      // seat is, by the juror's presence to this one — heard and moved,
      // the move stands; silent, or out of time on the turn by this
      // juror's clock, the escrow. Heard and not yet out of time is
      // nobody's to decide, and with no escrow said there is no other
      // side to rule for.
      final of = table.participantsAt(turn);
      final needed = table.majority(of);
      final forAction = race.forAction.intersection(of);
      final forRemoval = race.forRemoval.intersection(of);
      final awake = of.difference(forAction).difference(forRemoval).difference(race.forEnd).where((k) => !table.silent(k)).length;
      if (forAction.length + awake >= needed || forRemoval.length + awake >= needed) return;
      final held = table.botHolder(turn.hand, seat);
      final heard = held != null && table.liveJurors(turn.hand).contains(held);
      final TableEvent winner;
      final String side;
      if (heard && race.action != null) {
        winner = race.action!;
        side = 'action';
      } else if (race.boots.isNotEmpty && (!heard || table.outOfTime(seat))) {
        winner = race.boots.first;
        side = 'removal';
      } else {
        return;
      }
      _verdictAt[turn] = clock.nowMs;
      table.emit(EventKind.verdict, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'side': side, 'event': winner.toJson()},
          everywhere: true);
      return;
    }
    if (holder is! HumanSeat) {
      // A bot seat said two ways, neither able to carry. Either will
      // do — the same card, by two voices the seat may have — so the
      // rule is one every juror reaches alone: the lowest id. Nobody is
      // removed from a bot seat, so there is no other side.
      final a = race.action;
      if (a == null || race.rivals.isEmpty || !table.rivalsDeadlocked(turn, table.participantsAt(turn))) return;
      final winner = [a, ...race.rivals.values].reduce((x, y) => x.id.compareTo(y.id) <= 0 ? x : y);
      _verdictAt[turn] = clock.nowMs;
      table.emit(EventKind.verdict, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'side': 'action', 'event': winner.toJson()},
          everywhere: true);
      return;
    }
    final of = table.participantsAt(turn);
    final needed = table.majority(of);
    final forAction = race.forAction.intersection(of);
    final forRemoval = race.forRemoval.intersection(of);
    // Whoever has backed this person's leave has given their voice on
    // the seat's way out, and will back neither its move nor its boot;
    // and a person whose own leave is heard here is not coming back to
    // move, however long their device goes on being heard.
    final leaving = table.leaveBackersOf(holder.key);
    final left = table.hasLeft(holder.key);
    final awake = of
        .difference(forAction)
        .difference(forRemoval)
        .difference(race.forEnd)
        .difference(leaving)
        .where((k) => !table.silent(k) && !(left && k == holder.key))
        .toSet();
    final actionPossible = forAction.length + awake.length >= needed;
    final removalPossible = forRemoval.length + awake.difference({holder.key}).length >= needed;
    final said = _waitSaidAt[turn];
    if (said == null || clock.nowMs - said >= 10000) {
      _waitSaidAt[turn] = clock.nowMs;
      table.trace('appeal at $turn: ${forAction.length} for, ${forRemoval.length} against, of ${of.length}; '
          'awake ${awake.map((k) => '${k.substring(0, 4)} ${clock.nowMs - (table.lastHeard(k) ?? clock.nowMs)} ms ago')}; '
          'action ${race.action != null}; seat ${table.silent(holder.key) ? 'silent' : 'heard'}');
    }
    if (actionPossible || removalPossible) return;
    TableEvent winner;
    String side;
    if (!table.silent(holder.key) && !left) {
      if (race.action == null) return;
      winner = race.action!;
      side = 'action';
    } else {
      winner = race.boots.isNotEmpty
          ? race.boots.first
          : TableEvent.sign(signer, table: tableId, kind: EventKind.absent, body: {
              'hand': turn.hand,
              'turn': turn.index,
              'seat': seat,
            });
      side = 'removal';
    }
    _verdictAt[turn] = clock.nowMs;
    table.emit(EventKind.verdict, {'hand': turn.hand, 'turn': turn.index, 'seat': seat, 'side': side, 'event': winner.toJson()},
        everywhere: true);
  }
}
