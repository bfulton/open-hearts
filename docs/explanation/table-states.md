# The table's states

This page explains the states a live table, its turns, seats and hands
move through, and how each change between them is decided. The
protocol itself is [live play](live-play.md).

The states are code: `TableState`, `Owed`, `Exit` and `Removal` in
`packages/table/lib/src/rules.dart`, with the hand's phases from the
engine (`Phase`). The simulator reads every side's table after every
entry and fails a run where two sides disagree
([how it is checked](#how-it-is-checked)).

## How a transition is decided

Every transition is a function of the log: the referee's entries so
far, in their order, with the referee's times on them. Every side
applies the same rules to the same entries (`rules.dart`), so every
side is in the same state after every entry, and a side that reads the
log later (a device back from a reload, the house started again, the
verifier) comes to the same states too.

A clock does not propose anything. A deadline is past when an entry's
time is past it, and a side that sees one due asks the referee for an
entry with nothing but the time in it, a tick. The only thing a side
decides for itself is what it says, and what it says changes nothing
until the log carries it.

Before the referee there were three ways a transition could be decided:
on the record, by a majority's signatures or a jury's verdict; from the
record, worked out alike by every side; and *here*, by each side for
itself, from its own clock or from whom it heard. The last was where
sides came apart, and a table that came apart could not be put back
together. There is no *here* any more.

## The machines

### The table

The table is **waiting** until the log has its start, then **playing**.
It ends:

- **finished**, when somebody reaches the target and the last hand is
  audited;
- **ended**, when no person is left at it;
- **failed**, when a turn of the house's runs out, or when the log's
  first entry is not a start this side can read as its table. Nobody is
  rated on a failed game. The referee takes no such start
  ([what the referee takes](live-play.md#what-the-referee-takes)), so
  only a log kept wrongly fails that way.

Once it is over, the house says how it came out: an entry naming the
log by its length and hash as it stood at the end, the state and the
totals. The rules take it only when it names that log.

While a departed person's hand is opened, every clock stops
(`TableRules.paused`). That is a reading of the hand, not a state of the
table: it lifts when the hand is open, or when it is given up.

### A turn

A turn is **open** (`Owed`): owed by its actor, the person at the seat
or the house for a bot seat it holds, since an entry's time, with an
allowance from the table's clocks. It closes one of three ways:

- **taken**, by the first event for it from its actor that checks: a
  deal step with its proofs, a pass of three of the seat's cards, a
  legal card the seat holds;
- **lost**, when an entry's time is past its deadline: a person's seat
  is given to a bot (booted), and the house's loss fails the table;
- **gone**, when the seat is given up for any other reason before the
  turn is taken: its person's leave, their connection closed for the
  table's silence at the turn (absent), or the deal showing they lied.

The turns of a hand are each seat's steps of the deal (its keys, its
shuffle, its tokens, the lead card declared), the pass, the plays in
order, and the audit. A step of a seat nobody holds a key for is
nobody's turn: every side works it out.

### A seat

A person's seat is theirs until they **leave** (their own signed leave),
are **booted** (their clock out at their turn), are found **absent**
(their connection closed, as the referee's log has it, for the table's
silence at their turn) or are found to have **lied** (the deal shows
they declared the lead card nowhere). Each of these is a `Removal`,
with the entry and the hand it happened in. The seat is then a bot's,
the one the table's id names for it (`TableSpec.replacementFor`), and
never comes back to a person.

In the hand the person went in, their hand is opened from the escrow
(below) and every side plays it from the log. From the next hand the
house holds the seat. A bot seat at a sealed table is the house's from
the deal, every hand it is a bot's when the hand begins. A seat whose
person goes before they said their keys takes a secret anybody can
compute ([seats nobody holds](fair-deal.md#seats-nobody-holds)).

A seat is an account's, and an account plays on one device at a time
([one device at a time](service.md#one-device-at-a-time)). Another
device taking the account up while it sits here is no new transition:
the relay turns the old device's sockets away, the referee notes its
connection closed, and the seat is found absent at its turn, unless the
old device said its leave first.

### A hand

A hand is **dealt** (every seat's keys, shuffle and tokens, and the lead
card declared), then **passed**, or played at once on a hand with no
pass, then **played**, then **audited** (every keyed seat says its
secret), and is then over: the next is dealt, or the game is.

Two ways a hand is **given up**, unscored, with the next dealt in its
place ([the abandoned hand](#the-abandoned-hand)):

- nobody declared the lead card, so the hand is opened from the seats'
  audits, which shows who lied, and they are removed;
- a departed person's hand was not opened within the fixed clock.

## What each wait waits for

| Wait | Who can end it |
|---|---|
| a turn | its actor; or its deadline; and for a person whose connection is closed, the table's silence at the turn |
| a departed hand to open | the house's piece and one other person's; or the fixed clock (`fixedMs`), which gives the hand up |
| the house's word, once the game is over | the house |

Every wait has a deadline on the referee's clock but the last, and the
game is over by then either way: a kept game without the house's word
is not vouched for, and no rating is folded from it.

A side's own deal worker ([the fair deal](fair-deal.md)) is not a wait
of the table's: an entry being checked there is taken when the answer
comes back, and the table goes on meanwhile. If the worker fails for
good, the side can no longer deal (`TableClient.cannotDeal`), and a
person's device leaves; the table sees a seat that left.

## Never stuck, never apart

Two sides that have taken the same entries are in the same state,
because the state is a function of the entries. So sides cannot be
apart, as long as they are reading the same log, and there is only one.

A wait cannot be on nobody: every open turn has a deadline, a person's
closed connection has the silence, a departed hand has the fixed clock,
and the house's own deadline ends the game rather than holding it for
ever. The one thing that holds a table up is the referee being out of
reach. Then every side waits alike, the log is kept meanwhile, and
every side goes on alike when it is back.

## On the log

### The leave

A leave is the leaver's signed word, and it removes them at the entry
it is in. There is nothing to back and no race with a boot: whichever
of the leave and the deadline comes first in the log is what happened.
Whatever the seat owed when its person left is the bot's from that
entry: worked out by every side for the rest of the hand once the hand
is open, and the house's from the next.

### The escrow

When a person is removed mid-hand before their hand is in the open,
the hand is opened from the escrow: the house holds one half of their
secret, and every other person at the table the other
([escrow](fair-deal.md#escrow)). Each says its piece as a release, an
entry like any other, and the rules take a piece only for a seat
waiting to open. Every clock stops meanwhile. Once the house's piece
and one person's are in, the hand is open and every side plays it. A
hand still not open after the fixed clock is given up.

### The abandoned hand

A hand is given up, unscored and unaudited, and the next dealt in its
place, when nobody declared the lead card or a departed hand could not
be opened. A hand given up for a lie shows a seat that was dealt the
lead card and declared it nowhere, which only that seat could have
caused, so nobody can throw away a hand they merely dislike. One given
up for want of an opening needs a piece of the escrow nobody said. The
person who would not say theirs cannot turn a game into one nobody is
rated for this way: the game goes on.

### The house's word

The house's result names the log as it stood when the game ended, by
its length and hash (`LogHash`), with the state and the totals. A kept
game is checked against it: a log with any entry changed, dropped,
added or put in another order is not the one the house signed for
([game records](live-play.md#game-records)).

## The clocks

Every clock that decides anything is the table's, carried in its start
(`TableTiming`; [table clocks](../reference/configuration.md#table-clocks)):

- **A person's**: a grace for each decision and a bank for the hand
  (`graceMs`, `passGraceMs`, `bankMs`), and a fixed clock for their
  deal steps and audit (`fixedMs`), which also times an opening.
- **The house's**: a deadline for a bot's card or pass (`botActsMs`)
  and for its deal step or audit (`botDealsMs`), and the grace it is
  waited for after either before the game fails (`houseGraceMs`).
- **A closed connection's**: the silence after which a person is given
  up at their turn (`silenceMs`).

Pacing is each side's own and decides nothing: when it asks the referee
for the time, how it says again on a new socket what the log has not
carried, how long its screen holds a card.

## How it is checked

The simulator (`packages/table_sim`) runs whole tables over a referee on
a virtual clock, every person and the house as sides of their own. It
keeps every side's view of the table after every entry
(`TableRules.settledView`) and reports any entry after which two sides
saw different tables (`SimTable.lockstepProblems`).

The chaos walk (`chaos_walk.dart`) throws faults at a table at random:
people going every way at every moment, devices reloaded, sockets
dropped, phones off the network for a while, a slow line, the house
started again, a seat that lies. The explorer (`explore.dart`) plays a
short sealed game once per event and change: the event dropped on the
way, late, or sent twice. Each run is held to the same
(`tableProblems`): every side still reading the log saw the same table
after every entry and came to the same end; the log read alone comes
there too; the game is over as the faults allow; nobody lost a seat but
by a fault of their own; nothing was taken twice; and at a sealed table
the house's word on the end is in the log and true
([testing](testing.md#the-table),
[run the chaos walk](../how-to/run-the-chaos-walk.md)).
