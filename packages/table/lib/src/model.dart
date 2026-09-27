/// The protocol's states, named.
///
/// The client in client.dart implements these implicitly; this file is
/// the explicit version — the list the code and the docs are checked
/// against, and what the chaos test asserts over. Five machines — a
/// turn, a seat, a held bot seat, a hand, the table — and, for each
/// state that waits, what it waits for and who can move it
/// (docs/07-states.md, which is the prose of this file).
///
/// Every transition says how it is decided ([Decided]): as a settled
/// event every side holds the same, as a function of those, or by each
/// side for itself. The last kind is the one that can leave two sides
/// in different states with nothing in the record to reconcile them,
/// and each is listed as such below.
///
/// **A turn**, from the moment it opens:
///
/// ```
/// open ──action arrives──▶ acting ──majority──▶ settledByAction
///   │                        │
///   │ boot claimed           │ boot claimed
///   ▼                        ▼
/// contested ──majority for the action──▶ settledByAction
///   │  │
///   │  └──majority for the removal──▶ settledByRemoval
///   └──neither side can reach a majority──▶ split  (waits for the jury)
/// ```
///
/// A boot is claimed by the clock, fifteen seconds on turn, or for
/// silence, two minutes unheard; both are votes in the same race,
/// and a seat is only ever removed at its own turn or by its own signed
/// leave (client.dart, "silence", says why). A turn stuck for want of a
/// silent seat's vote is split. A settled turn never reopens; a split
/// one settles when the jury rules — for the action or for the removal,
/// the same two endings (client.dart, "the jury"). A turn nobody says
/// anything at goes from open to settledSilently: a bot seat nobody
/// holds, worked out by every side, and the audit of a held seat given
/// to the escrow, opened from its pieces.
///
/// **A seat**: human, until one of three doors — left (signed), booted
/// (a boot carried at its turn), absent (a silence claim carried, by
/// the players or by a verdict) — after which it is a bot for good. A
/// seat never comes back. Which door it went through is not always the
/// same everywhere ([seatExits]).
///
/// **The table**: playing, or paused waiting for the jury (a turn the
/// players cannot settle among themselves, appealed) or for peers (not
/// enough reachable to decide anything) or for the deal (a departed
/// seat's hand not yet opened from its escrow, or the lead card that
/// nobody declared), or finished, or failed: stopped for twenty seconds
/// at a seat nobody left could open, or at a turn put to a jury with
/// none of its jurors left to rule (client.dart, "juror quorum lost").
/// A pause always lifts when a decision lands; finished and failed are
/// terminal.
library;

import 'events.dart';
import 'signing.dart';

/// Where a turn's race stands.
enum TurnState {
  /// Nobody has acted or claimed anything.
  open,

  /// The seat's action is in, gathering witnesses.
  acting,

  /// A removal is claimed; the action may or may not be in.
  contested,

  /// Neither side can reach a majority any more. Only the jury can
  /// settle it, and does, for one side or the other.
  split,

  settledByAction,
  settledByRemoval,

  /// Closed with nothing said and nothing in the record: a turn every
  /// side works out for itself.
  settledSilently,
}

/// How a seat is held.
enum SeatState { human, left, booted, absent, bot }

enum TableState { playing, pausedForJury, pausedForPeers, pausedForDeal, finished, failed }

/// The transitions each machine allows, as data, so a test can check
/// that nothing observed steps outside them.
const turnTransitions = <TurnState, Set<TurnState>>{
  TurnState.open: {
    TurnState.acting,
    TurnState.contested,
    TurnState.settledByAction,
    TurnState.settledByRemoval,
    TurnState.settledSilently,
  },
  // A held seat's own audit, said and then outlived by its juror: the
  // side that gave the seat up closes it from the escrow's pieces.
  TurnState.acting: {TurnState.contested, TurnState.settledByAction, TurnState.settledSilently},
  TurnState.contested: {TurnState.split, TurnState.settledByAction, TurnState.settledByRemoval},
  TurnState.split: {TurnState.settledByAction, TurnState.settledByRemoval},
  TurnState.settledByAction: {},
  TurnState.settledByRemoval: {},
  TurnState.settledSilently: {},
};

const seatTransitions = <SeatState, Set<SeatState>>{
  SeatState.human: {SeatState.left, SeatState.booted, SeatState.absent},
  SeatState.left: {},
  SeatState.booted: {},
  SeatState.absent: {},
  SeatState.bot: {},
};

/// How each way out of a seat is decided. A boot and a claim of absence
/// are votes in the seat's own turn and settle as it does. A leave
/// needs nobody's agreement: it takes effect at the turn its author
/// put it at, at every side that has not already removed the seat
/// another way. So where a leave and a boot cross — the leave reaching
/// some sides only after the rest have booted the seat for its silence
/// — the door the seat went through, and the turn, is decided here, by
/// whichever arrived first.
const seatExits = <SeatState, Decided>{
  SeatState.booted: Decided.onRecord,
  SeatState.absent: Decided.onRecord,
  SeatState.left: Decided.here,
};

const tableTransitions = <TableState, Set<TableState>>{
  TableState.playing: {TableState.pausedForJury, TableState.pausedForPeers, TableState.pausedForDeal, TableState.finished, TableState.failed},
  TableState.pausedForJury: {TableState.playing, TableState.pausedForPeers, TableState.pausedForDeal, TableState.finished, TableState.failed},
  TableState.pausedForPeers: {TableState.playing, TableState.pausedForJury, TableState.pausedForDeal, TableState.finished, TableState.failed},
  TableState.pausedForDeal: {TableState.playing, TableState.pausedForJury, TableState.pausedForPeers, TableState.finished, TableState.failed},
  TableState.finished: {},
  TableState.failed: {},
};

/// How a transition is decided, and so whether every side makes it
/// the same way.
enum Decided {
  /// By a settled event — an action, a removal, a jury, a verdict — that
  /// every side holds the same, and a side that is behind is carried to.
  onRecord,

  /// By a function of the record, which every side works out alike.
  fromRecord,

  /// By each side for itself, from its own clock or from whom it hears.
  /// Nothing in the record says so: two sides can decide it differently
  /// and nothing reconciles them, and a side that joins later has to
  /// guess. These are what docs/07-states.md, "Decided here", lists.
  here,
}

/// **A bot seat a juror holds**, for one hand: held by its juror, until
/// the seat is given to the escrow — its juror not heard from for half
/// a minute, or out of time on a turn it has in front of it — and
/// played from then on by the first of the jurors holding a piece of
/// it. Given up for good for the hand; the next hand draws again.
enum HeldSeatState { held, escrowed }

const heldSeatTransitions = <HeldSeatState, Map<HeldSeatState, Decided>>{
  HeldSeatState.held: {HeldSeatState.escrowed: Decided.here},
  HeldSeatState.escrowed: {},
};

/// **A hand**:
///
/// ```
/// awaitingJury ──a jury that holds the bot seats (or none, at 40 s)──▶ dealing
/// dealing ──the declarations in──▶ passing ──every pass──▶ playing
///    │  │                           (or straight to playing, no pass)
///    │  └──nobody declared the lead card──▶ opening ──audits in──▶ givenUp
///    └──a held seat given up with steps still owed──▶ abandoned
/// playing ──the last trick──▶ auditing ──every audit──▶ over
/// ```
///
/// A seeded table's hand starts at passing or playing and ends at over
/// with no audit; a sealed one without bot seats skips awaitingJury.
enum HandState { awaitingJury, dealing, passing, playing, auditing, opening, over, givenUp, abandoned }

const handTransitions = <HandState, Map<HandState, Decided>>{
  // The jury is on the record; which draw a deal is sealed to is the
  // first to arrive here, held back two seconds for a late one, and the
  // table deals its bot seats in the open at forty seconds here.
  HandState.awaitingJury: {HandState.dealing: Decided.here},
  HandState.dealing: {
    HandState.passing: Decided.fromRecord,
    HandState.playing: Decided.fromRecord,
    HandState.opening: Decided.fromRecord,
    // A held seat given to the escrow while it owed a deal step.
    HandState.abandoned: Decided.here,
  },
  HandState.passing: {HandState.playing: Decided.fromRecord},
  HandState.playing: {HandState.auditing: Decided.fromRecord, HandState.over: Decided.fromRecord},
  // Every audit in: a person's and a held seat's own by their events,
  // a bot's nobody holds worked out, and a held seat's given to the
  // escrow closed from its pieces — escrowed or not being decided here.
  HandState.auditing: {HandState.over: Decided.here},
  HandState.opening: {HandState.givenUp: Decided.fromRecord},
  HandState.over: {},
  HandState.givenUp: {},
  HandState.abandoned: {},
};

/// What a state that waits is waiting for. Every wait names who can end
/// it ([Wait.movers]); a side waiting on nobody, on somebody who will
/// never act on it, or on somebody who waits on it in turn, is stuck,
/// and that is a fact about the sides' states rather than about how
/// long anything has taken (docs/07-states.md, "Stuck").
enum WaitKind {
  /// A seat's move: from its person, its juror, or once the seat is the
  /// escrow's, a juror holding a piece of it.
  action,

  /// Backing for an action or a claim this side holds, from the
  /// participants who have not given theirs — or, once a silent voter
  /// has split the turn, the hand's jurors' ruling.
  witnesses,

  /// A turn neither side can carry: the jury's ruling.
  verdict,

  /// A departed or escrowed seat's secret, from enough of those holding
  /// its pieces to open it.
  secret,

  /// A jury that can hold the hand's bot seats.
  jury,
}

/// One thing a side is waiting for, and who can end the wait. [movers]
/// is everyone whose event could: the seat's person or juror, the
/// participants whose backing is missing, the jury. A wait on
/// somebody outside the table — a juror yet to be drawn from whoever
/// is online — is [outside], and has no movers to name.
class Wait {
  const Wait(this.kind, {this.turn, this.seat, this.movers = const {}, this.outside = false});

  final WaitKind kind;
  final TurnId? turn;
  final int? seat;
  final Set<PublicKey> movers;
  final bool outside;

  @override
  String toString() => '${kind.name}${turn == null ? '' : ' at $turn'}${seat == null ? '' : ' (seat $seat)'}'
      '${outside ? ' from outside the table' : ' from ${movers.map((k) => k.substring(0, 4)).toList()}'}';
}

