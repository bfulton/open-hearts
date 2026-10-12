/// The escrow's custodians (docs/explanation/live-play.md): who holds
/// a piece of each held seat's secret, in what order, and how the list
/// grows as the hand draws jurors.
///
/// A bot seat a juror holds, and a person's seat, has its secret split
/// among custodians, so that the table can open the seat without the
/// one who left it. What the escrow holds of its own is here: the list
/// each seat's pieces are addressed by, grown on the record, the parts
/// that give a newcomer its share, and who says a given-up seat's
/// moves. It reads the table through [CustodyTable], which the table's
/// client gives it, and changes nothing there but by saying something.
library;

import 'package:deal/deal.dart';
import 'package:engine/engine.dart' show seatCount;

import 'clock.dart';
import 'events.dart';
import 'jury.dart';
import 'signing.dart';

/// What a table's escrow holds, as anyone may ask it
/// (TableClient.escrow).
abstract interface class Escrow {
  /// Every juror [hand]'s bot seats could be escrowed to, as this side
  /// has heard them drawn; a seat's own list, in the escrow's order,
  /// is [order].
  List<PublicKey> custodians(int hand);

  /// [seat]'s custodians at [hand], in the escrow's order.
  List<PublicKey> order(int hand, int seat);

  /// Who holds a piece of [seat]'s secret at [hand], as far as this
  /// side can tell.
  Set<PublicKey> pieceHolders(int hand, int seat);

  /// Whether anyone [up] could open [seat]'s hand at [hand].
  bool openableBy(int hand, int seat, bool Function(PublicKey) up);

  /// Whether this side holds a piece of some bot seat's secret at
  /// [hand].
  bool holdsPiece(int hand);
}

/// What the escrow reads of the table it serves, and how it says what
/// it has to.
abstract interface class CustodyTable {
  int get handNumber;
  bool get sealed;

  /// The deal of the hand in play, where this side has one.
  DealSession? get deal;

  /// The deal of [hand], where this side has one.
  DealSession? dealOf(int hand);

  /// Who holds each bot seat at [hand].
  Map<int, PublicKey> botHolders(int hand);

  /// Jurors of [hand] heard from lately, or drawn too recently to
  /// have been.
  Set<PublicKey> liveJurors(int hand);

  /// Every juror of [hand] as this side has them.
  Set<PublicKey> jurorsOf(int hand);

  /// The jury proposals drawn for [hand], in the juries' own order
  /// (compareJuries, client.dart).
  List<TableEvent> juryDraws(int hand);

  /// The jurors of the draw [id] at [hand], or null where it has not
  /// carried here.
  List<PublicKey>? juryById(String? id, int hand);

  /// The jury [hand]'s deal was sealed to.
  List<PublicKey> dealtTo(int hand);

  /// Whether [hand] was over before the summons that brought this side
  /// here.
  bool beforeSummons(int hand);

  /// The pieces of [seat]'s secret released at [hand] and refused
  /// here, taken again.
  void releasesAgain(int hand, int seat);

  /// Says an event of this side's, as the table says one.
  void emit(EventKind kind, Map<String, Object?> body);

  /// Keeps [event] until the table can take it.
  void defer(TableEvent event);

  void trace(String line);
}

class EscrowCustody implements Escrow {
  EscrowCustody({required this.me, required this.clock, required this.table});

  /// This side's key.
  final PublicKey me;
  final Clock clock;
  final CustodyTable table;

  // ---- whose the seat's moves are ----------------------------------------

  /// The custodians a piece of [seat] is worth sealing to: the first
  /// few that could say its moves ([sayers]), by their place in the
  /// escrow's own order. Every custodian holds a piece of its own, so
  /// one more opens the seat, and the side that has to open it is the
  /// one that will say the seat's moves — the first of this list
  /// ([firstToSay]). The next two are there so that its going does
  /// not cost another round of releases.
  ///
  /// Said again every few seconds from a fresh reading, so a list
  /// drawn up when somebody was still being heard corrects itself.
  Set<int> whoNeedsIt(int hand, int seat) {
    final order = this.order(hand, seat);
    const want = escrowThreshold + 1;
    final out = <int>{};
    for (final k in sayers(hand, seat)) {
      if (out.length >= want) break;
      out.add(order.indexOf(k) + 1);
    }
    // And filled out from the order itself where too few are known to
    // be live, so that the count is always met. A juror hears the
    // table rather than its fellow jurors — it dials the seats and
    // they dial it, and the jury never dials itself (_reachOut in
    // client.dart) — so its reading of which of them are about runs
    // behind theirs, and comes up short often enough that the fill is
    // what the count rests on rather than a safeguard against
    // something rare. Sealed to a custodian that has gone is a few
    // bytes wasted; sealed to too few is a seat the hand stops at.
    for (var i = 0; i < order.length && out.length < want; i++) {
      out.add(i + 1);
    }
    return out;
  }

  /// Whether this side is the one to say a given-up seat's moves: the
  /// first of the hand's custodians, in the escrow's own order, that
  /// is still being heard from ([sayers]).
  bool firstToSay(int hand, int seat) {
    final first = sayers(hand, seat).firstOrNull;
    return first != null && first == me;
  }

  /// Who could say a given-up seat's moves, first first: the hand's
  /// custodians still heard from, in the escrow's own order — leaving
  /// the seat's own juror to last, since the escrow took the seat from
  /// it for being gone or slow, and keeping it only for when it is the
  /// one juror back.
  List<PublicKey> sayers(int hand, int seat) {
    final live = table.liveJurors(hand);
    final held = table.botHolders(hand)[seat];
    final order = this.order(hand, seat).where(live.contains).toList();
    return [...order.where((k) => k != held), ...order.where((k) => k == held)];
  }

  /// [seat]'s custodians in the escrow's own order: the list its keys
  /// named, grown on the record ([applyGrowth]) — the order a sealed
  /// piece is addressed by. Before its keys are read here, the hand's
  /// jurors as this side has them.
  @override
  List<PublicKey> order(int hand, int seat) => table.dealOf(hand)?.custodiansOf(seat) ?? custodians(hand);

  // ---- topping the jury up -----------------------------------------------

  /// The hand's jurors as this side has them: the jury the deal was
  /// sealed to, then whoever has been drawn since, in the juries' own
  /// order (compareJuries, client.dart) and sorted within each. What a
  /// held seat's keys name as its custodians, and so on the record
  /// from there; the list grows after that only as the record names
  /// draws ([applyGrowth]), since the draws carried here since are
  /// this side's to know, in an order another side may not share.
  @override
  List<PublicKey> custodians(int hand) {
    final drawn = table.juryDraws(hand);
    final dealt = table.dealtTo(hand);
    if (drawn.isEmpty && dealt.isEmpty) return const [];
    final out = <PublicKey>[...dealt]..sort();
    for (final d in drawn) {
      for (final k in d.jurors.toList()..sort()) {
        if (!out.contains(k)) out.add(k);
      }
    }
    return out;
  }

  /// Gives whoever has joined the jury a share of every bot seat's
  /// secret, so that the jury tops back up instead of only shrinking
  /// (docs/explanation/live-play.md).
  ///
  /// Two holders make a newcomer's share between them, and which two
  /// is not agreed: each sender says what set it weighed its part
  /// against, and the newcomer sums a set once it holds all of it. So
  /// the senders are simply the lowest-indexed custodians still heard
  /// from — mostly the same two everywhere, and where they are not,
  /// the cost is a wait rather than a wrong share.
  void topUp() {
    final d = table.deal;
    if (d == null || !table.sealed) return;
    final hand = table.handNumber;
    // A custodian of a hand over before this side was summoned has the
    // share, read from the record, and no part in the hand: the parts
    // were its earlier client's to make, for a table long past them
    // ([CustodyTable.beforeSummons]).
    if (table.beforeSummons(hand)) return;
    final held = table.botHolders(hand);
    if (held.isEmpty) return;
    // Who this side would have answer, and whether it is one of them.
    // The jury's own liveness, not the table's: _recentWithin reads a
    // key never heard from as recent, which would put the very jurors
    // that went among the senders and leave the newcomer waiting on
    // parts nobody is making.
    final heard = table.liveJurors(hand);
    for (final seat in held.keys) {
      if (!d.holdsPieceOf(seat)) continue;
      // By the seat's own list, as the record has grown it
      // ([applyGrowth]): the place a part is made for is the place
      // its newcomer's piece is weighed at, everywhere.
      final custodians = d.custodiansOf(seat);
      if (custodians == null || custodians.length <= juryToHoldBots) continue;
      final live = [
        for (var i = 1; i <= custodians.length; i++)
          if (heard.contains(custodians[i - 1])) i,
      ];
      final have = live.take(escrowThreshold).toList();
      final mine = custodians.indexOf(me) + 1;
      if (mine < 1 || !have.contains(mine) || have.length < escrowThreshold) continue;
      for (var at = 1; at <= custodians.length; at++) {
        if (have.contains(at) || !_isNewCustodian(hand, custodians[at - 1])) continue;
        final key = '$seat|$at';
        if (clock.nowMs - (_toppedUpAt[key] ?? -topUpEveryMs) < topUpEveryMs) continue;
        final part = d.topUpPart(seat, at: at, have: have);
        if (part == null) continue;
        _toppedUpAt[key] = clock.nowMs;
        table.emit(EventKind.topup, {
          'hand': hand,
          'about': seat,
          'at': at,
          'have': have,
          'from': part['from'],
          'holder': part['holder'],
          'part': part['part'],
        });
      }
    }
  }

  /// Whether this side holds a piece of some bot seat's secret at
  /// [hand] — what a juror brought on is given, and what says the
  /// giving worked.
  @override
  bool holdsPiece(int hand) {
    final d = table.dealOf(hand);
    if (d == null) return false;
    return table.botHolders(hand).keys.any(d.holdsPieceOf);
  }

  /// Whether [who] came to the jury after the deal was sealed to it.
  bool _isNewCustodian(int hand, PublicKey who) {
    final dealt = table.dealtTo(hand);
    return dealt.isNotEmpty && !dealt.contains(who);
  }

  /// When this side last sent a part, by seat and index.
  final Map<String, int> _toppedUpAt = {};

  /// Parts heard, by hand, to carry forward to whoever is behind.
  final Map<int, List<TableEvent>> _topUps = {};

  /// The parts heard at [hand].
  List<TableEvent> topUpsOf(int hand) => _topUps[hand] ?? const [];

  /// How often a part is said again for the same newcomer: a part can
  /// go missing, and the sender never learns whether the set it chose
  /// was the one that completed.
  static const topUpEveryMs = 10000;

  void onTopUp(TableEvent event) {
    final d = table.deal;
    // As a release: kept until there is a deal to put it in.
    if (d == null) return table.defer(event);
    if (event.hand > table.handNumber) return table.defer(event);
    if (event.hand < table.handNumber) return;
    final about = event.about;
    if (about < 0 || about >= seatCount) return;
    // Kept, and carried forward like a release. A part is a broadcast
    // and its recipient is the one peer most likely to miss it: a
    // juror brought on mid-hand is behind by a whole hand, and may
    // not have been listening at all when the part went out. Whoever
    // carries it forward hands the part over with everything else.
    final kept = _topUps.putIfAbsent(event.hand, () => []);
    if (!kept.any((r) => r.id == event.id)) kept.add(event);
    final at = event.body['at'];
    if (at is! int || at < 1) return;
    // A part made out past the end of the list as this side has it is
    // for a custodian this side has no place for yet — the seat's keys
    // unread, or the play that named the newcomer's draw not yet
    // carried here ([applyGrowth]). A juror carried the record gets
    // the parts made for it among the very events that say who it is,
    // so this is the ordinary case for the one peer the part is for.
    // That custodian may be this side itself, so a juror keeps it for
    // the drain after each settled turn to try again; anyone else will
    // never be a custodian and drops it.
    //
    // Within the list, this side knows its own place, and only the
    // part made out to that place is any use here. Jurors brought on at
    // several bot seats make a lot of parts, and keeping the others
    // would mean trying each of them again at every turn that settles.
    final mine = d.custodianIndexOf(about);
    if (at > d.custodianCount(about)) {
      table.trace('top-up for seat $about at $at, past the ${d.custodianCount(about)} custodians known here');
      return table.jurorsOf(event.hand).contains(me) ? table.defer(event) : null;
    }
    if (at != mine) return;
    final took = d.acceptTopUpPart({
      'about': about,
      'at': at,
      'have': event.body['have'],
      'from': event.body['from'],
      'holder': event.body['holder'],
      'part': event.body['part'],
    });
    table.trace('top-up for seat $about at $at from ${event.body['from']} of ${event.body['have']}: '
        '${!took ? 'refused' : d.holdsPieceOf(about) ? 'the share is whole' : 'kept, waiting on the rest of the set'}');
  }

  // ---- the custodians, grown on the record -------------------------------
  //
  // A held seat's pieces are indexed by each custodian's place in a
  // list: the one the seat's keys named, and after it whoever the
  // hand's later draws bring in. Two draws of one hand can carry in
  // either order, at two sides the one way and the other, and at the
  // verifier in neither; grown as each draw carried, a newcomer given
  // its share at one place would have its piece weighed at another.
  // So the order is the record's, as the draw a deal is
  // sealed to is: a person's own play names the draws that have grown
  // the escrow since the last one that did, and every side grows the
  // list from those plays in the order the record has them, the
  // verifier with it. People's plays, and not every move, because
  // they carry one after another and with an event every time: passes
  // race side by side and settle in a different order at each side,
  // and a bot seat's move settles with nothing said where the seat is
  // everyone's to work out.

  /// The draws named in `hand`'s people's plays so far, in the order
  /// the record names them.
  final Map<int, List<String>> _grown = {};

  /// The draws this side's next play names: the hand's, in the juries'
  /// own order, that bring someone into a held seat's escrow and have
  /// not been named yet.
  List<String> growthToName(int hand) {
    final d = table.dealOf(hand);
    final held = table.botHolders(hand).keys;
    if (d == null || held.isEmpty) return const [];
    final named = {...?_grown[hand]};
    return [
      for (final j in table.juryDraws(hand))
        if (!named.contains(j.id) &&
            held.any((s) {
              final c = d.custodiansOf(s);
              return c == null || j.jurors.any((k) => !c.contains(k));
            }))
          j.id,
    ];
  }

  /// A person's play has carried: the draws it names go on the list.
  void takeGrowth(int hand, TableEvent play) {
    final named = play.body['grew'];
    if (named is! List) return;
    final list = _grown.putIfAbsent(hand, () => []);
    for (final id in named) {
      if (id is String && !list.contains(id)) list.add(id);
    }
    applyGrowth(hand);
  }

  /// Grows each held seat's custodians by the draws the record names,
  /// in its order. A draw named and not carried here yet holds up the
  /// ones after it, since a place is a place in the whole list; its
  /// carrying brings it on. Pieces a newcomer released before this
  /// side had it on the list were refused, and are taken again.
  void applyGrowth(int hand) {
    final d = table.dealOf(hand);
    final named = _grown[hand];
    if (d == null || named == null) return;
    final added = <PublicKey>[];
    for (final id in named) {
      final jurors = table.juryById(id, hand);
      if (jurors == null) break;
      added.addAll(jurors.toList()..sort());
    }
    if (added.isEmpty) return;
    for (final seat in table.botHolders(hand).keys) {
      final before = d.custodianCount(seat);
      d.extendCustodians(seat, added);
      if (d.custodianCount(seat) == before || !d.awaitsSecret(seat)) continue;
      table.releasesAgain(hand, seat);
    }
  }

  // ---- who holds a piece -------------------------------------------------

  /// Whether anyone [up] could open [seat]'s hand at [hand]: a held
  /// seat's own juror, or [escrowThreshold] of the jurors holding a
  /// piece of its secret ([pieceHolders]); a departed person's, any
  /// one of the jury the deal was sealed to, beside a person's piece.
  /// A hand drawn no jury is escrowed to the people alone, and is no
  /// jury's to lose.
  @override
  bool openableBy(int hand, int seat, bool Function(PublicKey) up) {
    if (table.juryDraws(hand).isEmpty) return true;
    final holder = table.botHolders(hand)[seat];
    final pieces = pieceHolders(hand, seat).where(up).length;
    if (holder != null) return up(holder) || pieces >= escrowThreshold;
    return pieces >= 1;
  }

  /// Who holds a piece of [seat]'s secret at [hand], as far as this
  /// side can tell: the jury the deal was sealed to, which the seat's
  /// keys split it among, and a juror drawn since once it has been
  /// sent a whole set of parts of one ([topUp]). Not a juror drawn
  /// since that has not: it is on the list of custodians, and heard
  /// from, and holds nothing. A jury drawn after the holders of the
  /// pieces went has nobody to be given them by — a newcomer's piece
  /// is made by [escrowThreshold] of the old — and counting it would
  /// take the seat for one the jury could still open, and sit at its
  /// turn for good.
  @override
  Set<PublicKey> pieceHolders(int hand, int seat) {
    // A person's seat: the custodians its keys named, which is the jury
    // in force when it keyed, whatever draw the hand was sealed to. A
    // hand dealt its bot seats in the open is sealed to no draw at all,
    // and read from that, a leaver's hand would have nobody holding a
    // piece of it, and the game would end over a seat that can be
    // opened.
    if (table.botHolders(hand)[seat] == null) {
      final named = table.dealOf(hand)?.custodiansOf(seat);
      if (named != null) return named.toSet();
    }
    final dealt = table.dealtTo(hand);
    if (dealt.isEmpty) return const {};
    final custodians = order(hand, seat);
    final out = {...dealt};
    final sets = <String, Set<int>>{};
    for (final e in _topUps[hand] ?? const <TableEvent>[]) {
      if (e.about != seat) continue;
      final at = e.body['at'], from = e.body['from'], have = e.body['have'];
      if (at is! int || from is! int || have is! List || at < 1 || at > custodians.length) continue;
      if (from < 1 || from > custodians.length || custodians[from - 1] != e.author) continue;
      final set = [for (final i in have) if (i is int) i];
      if (set.length < escrowThreshold || !set.contains(from)) continue;
      final got = sets.putIfAbsent('$at|${set.join(',')}', () => {})..add(from);
      if (set.every(got.contains)) out.add(custodians[at - 1]);
    }
    return out;
  }
}
