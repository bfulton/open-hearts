# The table's states

This page explains the states a live table, its turns, seats and hands
move through, how each change between them is decided, and why so many
of them are on the record. The protocol itself is
[live play](live-play.md).

The machines are code: `turnTransitions`, `seatTransitions` and
`seatExits`, `heldSeatTransitions`, `handTransitions` and
`tableTransitions` in `packages/table/lib/src/model.dart` list every
state, every way out of it, and how each is decided. The simulator reads
every side against them (`packages/table_sim/lib/src/structure.dart`),
and the chaos walk fails any run that steps outside them.

## How a transition is decided

Every transition is one of three kinds (`Decided`):

- **On the record.** A signed event, settled the way a turn is: backed
  by a majority of the people at the table, or ruled on by the jury.
  Every side ends up holding the same event, and a side that falls
  behind is carried forward to it.
- **From the record.** A function of events already on the record, which
  every side works out alike. A bot seat nobody holds plays this way:
  its move is computed, not said.
- **Here.** Each side decides it for itself, from its own clock or from
  whom it happens to hear. Nothing in the record says so, so two sides
  can decide it differently, and a side that joins later can only guess.

The first two cannot leave two sides in different states for good; the
third can. So every transition but one is on the record or follows
from it, and clocks only *propose* transitions.

## The machines

### A turn

A turn is **open** until somebody says the seat's move, and **acting**
once its actor has: its person; for a held bot seat, its juror; and once
the record gives a held seat to the escrow, the first custodian still
heard, the seat's own juror last. A person at the table can **contest**
the turn instead: a boot when the seat's clock runs out, a claim of
absence after the silence clock (`silenceMs`), or, at a held seat, a
claim for the escrow when its juror is out. A majority of the people
settles a turn **by the action** or **by the removal**. Where neither can
reach a majority the turn is **split**, and the jury rules it.

At a held seat, the escrow carried reopens the turn for the escrow:
keeping a move already said for the seat, or waiting for one. A turn
nobody needs to say is **settled silently**, worked out by every side
alike: a bot seat nobody holds, or the audit of a held seat the record
gave to the escrow, closed from its pieces. A turn nobody left can move
is **ended** by the people ([the lost-quorum ending](#the-lost-quorum-ending)).

### A seat

A person's seat is theirs until they **leave** (their own signed word),
are **booted** (a boot carried at their turn) or are found **absent** (a
claim of silence carried by the people or by a verdict). A bot seat is a
bot from the start. A seat never comes back, and all three exits are on
the record.

A seat is an account's, and an account plays on one device at a time
([one device at a time](service.md#one-device-at-a-time)). Another
device taking the account up while it sits here is no new transition:
the device at the seat leaves, by its own signed leave where any path is
still open to it, and otherwise falls silent, cut off by the relay,
which is one of the three exits above. The account's new device is never
one of the table's jurors, and a juror whose account is taken up
elsewhere is a juror gone.

### A held bot seat, for one hand

A bot seat the jury holds is **held** by its juror until a person claims
it for the escrow, and **escrowed** from then on, played by a juror
holding a piece of it. The claim is made at the seat's own turn when the
juror has not been heard from for the juror silence clock
(`jurorSilenceMs`), or has had the turn in front of it longer than a
held seat's deadlines allow (`botActsMs` for a play or a pass,
`botDealsMs` for a deal step or its audit), counted once the juror is
heard at the hand and not while this side is behind. The claim is
carried as a boot is.

### A hand

A hand of a sealed table with bot seats **awaits a jury** until the first
person's keys name a draw that can hold the bot seats. It is **dealt**,
then **passed** (or played at once, on a hand with no pass), **played**
and **audited**, and is then **over**. Two other endings follow from the
record: a hand whose lead card nobody declared is **opened** from the
seats' audits and **given up**, and a hand whose held seat was escrowed
while it still owed a deal step is **abandoned**. A seeded table's hand
starts at the pass or the play and ends with no audit, and a sealed table
with no bot seats needs no jury.

### The table

The table is **playing**, or **paused** while it says what it is waiting
for: the jury, its peers, or the deal. It ends **finished** or **failed**.
A pause is a reading of the hand's and turns' states, not a state of its
own, and lifts when a decision lands. A failure is on the record where a
majority of the people can say so, and decided here where they cannot
([decided here](#decided-here)).

## What each waiting state waits for

A side that is waiting names what for, and who can end it
(`TableClient.waits`, `WaitKind` in `model.dart`):

| Wait | Who can end it |
|---|---|
| a seat's move | its person, or the people by a boot or a claim of silence; a held seat's juror, or the people by a claim for the escrow; once escrowed, a custodian with its key |
| backing for an action or a claim this side holds | the people who have not given theirs; once a silent voter has split the turn, the hand's jurors |
| the jury's ruling on a split turn | the hand's jurors |
| a departed or escrowed seat's secret | enough of those holding a piece: for a held seat, its own juror or two custodians; for a departed person's, one juror of the draw the deal was sealed to beside a person's piece |
| a jury that can hold the bot seats | somebody outside the table, not yet drawn |

A bot seat nobody holds is never waited on: every side works its move
out, waiting only for the seat's secret if its cards are not open yet.

A side's own deal worker ([the fair deal](fair-deal.md)) is not a wait of
the table's: a step being checked there is kept until the answer comes
back. If the worker fails for good, the side can no longer deal
(`TableClient.cannotDeal`) and leaves; the table sees a seat that left.

## Stuck and apart

A wait is **covered** when someone who can end it is up and holds what
ends it or is on the way to it: the move or the removal has been made or
is owed; the backing has been given and is repeated until the turn
settles; a juror is up to rule a turn the voters cannot carry; the turn
is decided on the record, which a side behind is carried to; or enough
of the seat's pieces to open it are held by sides that are up.

A side is **stuck** when a wait of its is:

- **on nobody**: nobody up can end it. The side may be paused, saying
  why, and still wait for good;
- **left behind**: everyone up who could end it has moved past it in a
  way no rule brings back: past its hand without deciding it, closed
  with nothing said, never giving up the seat whose pieces the side
  wants, or finished the game without it;
- **in a cycle**: the sides that could end it wait on each other.

This is a fact about states, not about how long anything has taken.

Sides are **apart** when they disagree on something each decides for
itself: a held seat escrowed at one and not another; a hand abandoned at
one and not another; a deal sealed to different draws; the game failed
at one and not another; a turn closed silently at one and decided on the
record at another; a person removed at different turns. Being apart is
not stuck in itself, but it is how sides become stuck, which is why each
of these is on the record.

## On the record

### The leave

A leave is carried where it is said. The leaver's signature is its own
vote, the others back it as it reaches them (there is nothing to judge,
it being the leaver's own word), and a majority of the people at its
turn carries it; at a table of two, the other person's backing is that
majority. Each person backs one way out of a seat (a leave, or a boot
or claim of silence at the seat's turn), and not the other while the one
it backed can still carry. Two majorities of one table meet in somebody,
so a leave and a boot cannot both carry, and every record, the jurors'
too, names the same exit. The leaver has gone, so whoever holds the
leave carries it forward with its backing; a juror carries it on the
backing it is handed.

It is not settled in the seat's own next turn: at a table of two that
turn could never come, since every turn before it needs both people.
Where one voice per exit leaves no majority either way (two backing
the leave, two booting the seat), the turn is split and the jury rules
it. A person known to have backed a seat's leave is not a vote still to
come for its boot. The verifier turns down a leave without its majority
(`packages/table/test/leave_on_record_test.dart`).

### The escrow

A person at the table whose clocks say a held seat's juror is out claims
the seat for the escrow at that turn, with an `escrow` event. The claim
is a vote in the turn's race. A majority of the people carries it; where
they split between the juror's move and the claim, the jury rules by
the juror's presence to it. From there the seat is the escrow's for the
rest of the hand:

- it is played by the first of the hand's custodians still heard, the
  seat's own juror last, and that custodian says again whatever the
  seat's turn already holds, since the move's author may be gone;
- a move by the seat's juror that lands after the escrow is as good as
  the escrow's own (the same card by another voice), and the reopened
  turn keeps it and its backing; only a side whose voice went to the
  escrow votes again;
- claims, their witnesses and a ruling for the escrow are taken even at
  a turn already settled by the move, and the escrow is recorded beside
  it;
- the escrowed seat's audit is nobody's move: not said, not taken, and
  closed from the seat's pieces.

The verifier holds a record to the same: an escrow claimed by a person
at the table, carried or ruled for, once a hand, for a seat the hand's
draw gave a juror; only that juror moving the seat before, any juror of
the hand after (`escrow_on_record_test.dart`).

### The abandoned hand

Both follow from the escrow. A held seat escrowed while it still owes a
deal step gives the hand up, and the verifier asks for that escrow at
one of the seat's deal steps. A side behind is carried to the escrow
like any removal; from any turn of a hand given up in its deal, the
hand's removals are sent, since nothing settles at the turn such a hand
stops at (`undealt_hand_test.dart`). A jury carried for a hand the table
has left rebuilds nothing.

### The draw a deal is sealed to

A hand's bot seats are held by the draw its deal is sealed to, and the
record says which. Every seat's keys name the draw they were sealed to
(the draw's event id, or none), and the draw named by the keys of the
first person to key the hand is the hand's, at every side and at the
verifier: lowest seat first, passing over a person removed at their keys
or gone before them. A person's keys name a carried draw that can hold
every bot seat. A hand nobody at the table can key is sealed to none.
Until the first person's keys have settled at a side:

- a held seat's juror makes no keys, and its time for them has not
  started;
- no side takes a held seat's keys, and afterwards takes them only
  naming the same draw, from the juror that draw names for the seat;
- no bot seat's keys are settled silently;
- nobody claims a held seat for the escrow at its keys; a claim that
  comes is kept until the record has said, since a claim names the seat,
  not the juror.

A seat's holder is then whoever's keys settled its first deal round.
Keys that arrive before the draw they name has carried are kept and
taken up when it carries; so is a verdict carrying a held seat's keys
that arrives before the record has said which draw the hand is sealed
to (`late_juror_verdict_test.dart`). A summons carries the hand's draws
with their witnesses, so a juror brought in reads the table's draw from
the moment it is summoned (`sealed_to_draw_test.dart`).

### The escrow's custodians

A held seat's pieces are indexed by each custodian's place in a list:
the jury the seat's keys named, then whoever the hand's later draws
bring in. Two draws of one hand can carry in either order at different
sides, so the order is on the record too. A person's own play names the
draws that have brought somebody into a held seat's escrow since the
last play that did; every side grows each held seat's list from those
plays in record order, and the verifier reads the same plays ahead of
the replay. A draw named and not yet carried at a side holds up the
ones after it there. Every index reads the seat's own list: the place a
part is made for, the custodian a piece is sealed to, and which
custodian plays an escrowed seat (`top_up_test.dart`).

People's plays carry this because they settle one after another with an
event every time; passes and deal steps settle in different orders at
different sides. The cost is a wait: a newcomer gets its share only
after the next person's play, and a draw carried after the hand's last
one grows nothing in that hand. A piece from a newcomer a side has no
place for yet is refused, and taken again as the list grows.

### The lost-quorum ending

A side stopped for the lost-quorum clock (`quorumLostMs`) at a turn nobody left
can move (a seat nobody left can open, or a turn put to a jury none of
whose jurors is left) claims the game's end at that turn. The claim is
a vote in the turn's race, the third way a turn can go beside the move
and the removal; a person has one voice at a turn. A person stopped at
the same turn backs it at once; a majority of the people carries it, and
every side ends the game there (`TurnState.ended`). Where a table is
stopped at several turns of one position, every side names the lowest
seat's. The end is the last thing at its position. The verifier reads a
record ending with it as a game ended, not complete and nobody rated,
and turns down one that goes on past it, lacks its majority, or has it
claimed by somebody not at the table or at another turn
(`ended_on_record_test.dart`).

A voice already given at the turn waits for the end the rest carry and
takes it with them. A side that has seen a departed seat's hand open, and
so would work its move out, holds at the turn while the end can still
carry, and lets go once the rest are known to stand past it. A side that
has ended the game for itself says nothing more, and is not a vote still
to come.

A seat's piece holders are the custodians its keys named, including at a
table of four people, whose hands are sealed to no draw but are still
escrowed to the jury (`quorum_lost_test.dart`).

## Decided here

One transition is still decided by each side for itself: **the game's
end for a lost quorum where no majority can be had.** That is a turn
split between a card and a boot with the jury gone and every voice
spent, or the last person at a table of two hearing too little of the
table. Nothing can go on the record without a majority or a jury, so
the side ends the game for itself. Its record stops at the turn, a
prefix of the table's. The rule standing in for a record is the silence
clock: a side that hears too little of the table ends only once everyone
it cannot hear has been silent as long as a person is given before the
table removes them (`silenceMs`).

## The clocks that stay

A transition on the record needs no rule for guessing what the others
decided, but it still needs clocks. The clocks are of three kinds:

- **Pacing:** when to say something again: heartbeats, repeats of an
  unsettled action, carrying a peer forward, catch-up budgets, top-up
  and release repeats, how often a jury is proposed. None decides a
  state.
- **Noticing absence:** silence from a person (`silenceMs`) and from a
  juror (`jurorSilenceMs`), "heard lately" for who is here, how long a
  juror's position may stand still before it counts as stopped rather
  than catching up, and how long a juror goes without hearing an appeal
  before taking it as no longer standing (`appealStandsMs`), which is the
  juror's own way of noticing it has lost the table. Nothing but time tells gone from
  slow.
- **Deadlines on someone present:** a person's grace and bank, and a
  held seat's deadlines for a play and for a deal step. These are rules
  of the game, like a chess clock.

The deadlines, the silences that count as absence and the lost-quorum
wait are the table's, not each side's: the starter's remote config
chooses them and the signed start event carries them (`TableTiming`),
so every side and every juror times the same table by the same clocks
([table clocks](../reference/configuration.md#table-clocks)). Pacing is
each device's own. Each clock *proposes* a transition; the
table settles it on the record.

## How it is checked

The structure checker (`packages/table_sim/lib/src/structure.dart`)
reads every side against these machines during a run and at its end, reporting waits stuck and sides apart. What counts
is what is still read at the end among sides still online; mid-run, an
event in flight is ordinary.

The chaos walk and the explorer drive the machines through random and
systematic faults, and fail a run on any broken invariant
([testing](testing.md#the-table)).

With every transition above on the record, nothing stuck and nothing
apart is read at the end among sides still playing, except where one
side ended the game for itself ([decided here](#decided-here)).
