/// The protocol's states, named.
///
/// The client in client.dart implements these implicitly; this file is
/// the explicit version — the list the code and the docs are checked
/// against, and what the chaos test asserts over. Three machines:
///
/// **A turn**, from the moment it opens:
///
/// ```
/// open ──action arrives──▶ acting ──majority──▶ settledByAction
///   │                        │
///   │ boot/absence claimed   │ boot/absence claimed
///   ▼                        ▼
/// contested ──majority for the action──▶ settledByAction
///   │  │
///   │  └──majority for the removal──▶ settledByRemoval
///   └──everyone voted, no majority──▶ split  (waits for the jury)
/// ```
///
/// A bot's turn goes straight from open to settledByAction. A settled
/// turn never reopens; a split one settles only when the jury decides.
///
/// **A seat**: human, until one of three doors — left (signed), booted
/// (a boot carried), absent (an absence carried) — after which it is a
/// bot for good. A seat never comes back.
///
/// **The table**: playing, or paused waiting for the jury (a removal the
/// players cannot decide among themselves) or for peers (not enough
/// reachable to decide anything), or finished. A pause always lifts when
/// a decision lands; finished is terminal.
library;

/// Where a turn's race stands.
enum TurnState {
  /// Nobody has acted or claimed anything.
  open,

  /// The seat's action is in, gathering witnesses.
  acting,

  /// A removal is claimed; the action may or may not be in.
  contested,

  /// Everyone has voted and nobody has a majority. Only the jury can
  /// settle it.
  split,

  settledByAction,
  settledByRemoval,
}

/// How a seat is held.
enum SeatState { human, left, booted, absent, bot }

enum TableState { playing, pausedForJury, pausedForPeers, finished }

/// The transitions each machine allows, as data, so a test can check
/// that nothing observed steps outside them.
const turnTransitions = <TurnState, Set<TurnState>>{
  TurnState.open: {TurnState.acting, TurnState.contested, TurnState.settledByAction, TurnState.settledByRemoval},
  TurnState.acting: {TurnState.contested, TurnState.settledByAction},
  TurnState.contested: {TurnState.split, TurnState.settledByAction, TurnState.settledByRemoval},
  TurnState.split: {TurnState.settledByAction, TurnState.settledByRemoval},
  TurnState.settledByAction: {},
  TurnState.settledByRemoval: {},
};

const seatTransitions = <SeatState, Set<SeatState>>{
  SeatState.human: {SeatState.left, SeatState.booted, SeatState.absent},
  SeatState.left: {},
  SeatState.booted: {},
  SeatState.absent: {},
  SeatState.bot: {},
};

const tableTransitions = <TableState, Set<TableState>>{
  TableState.playing: {TableState.pausedForJury, TableState.pausedForPeers, TableState.finished},
  TableState.pausedForJury: {TableState.playing, TableState.pausedForPeers, TableState.finished},
  TableState.pausedForPeers: {TableState.playing, TableState.pausedForJury, TableState.finished},
  TableState.finished: {},
};
