# 07 — The table's states

Every table state, every way out of it, and who can take each one.
`packages/table/lib/src/model.dart` is the same thing as code, and the
simulator reads every side against it
(`packages/table/lib/src/sim/structure.dart`). The protocol these
machines describe is [doc 04](04-live-play.md).

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

```
open ──action──▶ acting ──majority──▶ settledByAction
  │                │
  │ claim          │ claim (a boot, silence, or the escrow)
  ▼                ▼
contested ──majority for the action──▶ settledByAction
  │   └──majority for the removal──▶ settledByRemoval
  └──neither can reach one──▶ split ──the jury's ruling──▶ either of those
open ──nothing said, everyone works it out──▶ settledSilently
contested, split ──the escrow carried at a held seat──▶ acting or open
any unsettled turn ──the end carried, nobody left to move it──▶ ended
```

| From | To | Decided | Who can move it |
|---|---|---|---|
| open | acting | on the record | the seat's actor: its person; a held seat's juror; once the record gives a held seat to the escrow, the first custodian still heard, the seat's own juror last |
| open, acting | contested | on the record | any person at the table: a boot when the clock runs out, a claim of absence after two minutes' silence; at a held seat, a claim for the escrow when its juror is out |
| acting, contested | settledByAction | on the record | the people who have not backed the action |
| contested | settledByRemoval | on the record | the people who have not backed the removal |
| contested | split | from the record | nobody: it is what the backing adds up to |
| split | settled | on the record | the jury |
| contested, split | acting, open | on the record | the escrow carried at a held seat: the turn is the escrow's, keeping a move already said for the seat (acting) or waiting for one (open); at an audit, keeping nothing |
| open | settledSilently | from the record | nobody — every side works it out: a bot seat nobody holds; the audit of a held seat the record gave to the escrow, from its pieces |
| open, acting, contested | ended | on the record | the people, when nobody left can move the turn (below) |

### A seat

`human`, until `left` (their own signed leave), `booted` (a boot carried
at their turn) or `absent` (a claim of silence carried by the people or
by a verdict). A `bot` seat is a bot from the start. A seat never comes
back. All three exits are on the record.

| From | To | Decided |
|---|---|---|
| human | booted, absent | on the record: votes in the seat's own turn, settled as it is |
| human | left | on the record: the leaver's word at the turn they stood at, carried by a majority of the people there |

A seat is an account's, and an account plays on one device at a time
([doc 06](06-service.md)). Another device taking the account up while
it sits here is no new transition: the device at the seat leaves, by
its own signed leave where any path is still open to it, and otherwise
falls silent, cut off by the relay — one of the three exits above. The
account's new device is never one of the table's jurors. A juror whose
account is taken up elsewhere is a juror gone.

### A held bot seat, for one hand

`held` by its juror → `escrowed`, played from then on by a juror holding
a piece of it. **On the record**: a person claims the seat for the escrow
at the seat's own turn when the juror has not been heard from for half a
minute, or has had the turn in front of it too long — 15 s for a play or
a pass, 40 s for a deal step or its audit, counted once the juror is
heard at the hand and not while this side is behind. The claim is
carried as a boot is.

### A hand

```
awaitingJury ──the first person's keys name a draw that holds the bot seats──▶ dealing
dealing ──declarations in──▶ passing ──every pass──▶ playing
   │  │                        (straight to playing on a hold hand)
   │  └──nobody declared the lead card──▶ opening ──audits in──▶ givenUp
   └──a held seat escrowed with steps still owed──▶ abandoned
playing ──last trick──▶ auditing ──every audit──▶ over
```

| From | To | Decided |
|---|---|---|
| awaitingJury | dealing | on the record: the draw named by the keys of the first person to key the hand |
| dealing | passing, playing, opening | from the record |
| dealing | abandoned | from the record: follows from the escrow of a held seat that still owed a step |
| passing | playing | from the record |
| playing | auditing (sealed), over (seeded) | from the record |
| auditing | over | from the record: every audit in, an escrowed seat's closed from its pieces |
| opening | givenUp | from the record |

A seeded table's hand starts at passing or playing and ends at over. A
sealed table with no bot seats skips awaitingJury.

### The table

`playing`; `pausedForJury`, `pausedForPeers` or `pausedForDeal` while it
says what it is waiting for; `finished`; `failed`. A pause is a reading
of the hand's and turns' states, not a state of its own, and lifts when
a decision lands. `failed` is on the record where a majority of the
people can say so, and decided here where they cannot (below).

## What each waiting state waits for

A side that is waiting names what for, and who can end it
(`TableClient.waits`):

| Wait | Who can end it |
|---|---|
| a seat's move | its person, or the people by a boot or a claim of silence; a held seat's juror, or the people by a claim for the escrow; once escrowed, a custodian with its key |
| backing for an action or a claim this side holds | the people who have not given theirs; once a silent voter has split the turn, the hand's jurors |
| the jury's ruling on a split turn | the hand's jurors |
| a departed or escrowed seat's secret | enough of those holding a piece: for a held seat, its own juror or two custodians; for a departed person's, one juror of the draw the deal was sealed to beside a person's piece |
| a jury that can hold the bot seats | somebody outside the table, not yet drawn |

A bot seat nobody holds is never waited on: every side works its move
out, waiting only for the seat's secret if its cards are not open yet.

A side's own deal worker ([doc 03](03-fair-deal.md)) is not a wait of
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

- **on nobody**: nobody up can end it — the side may be paused, saying
  why, and still wait for good;
- **left behind**: everyone up who could end it has moved past it in a
  way no rule brings back — past its hand without deciding it, closed
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
of these is now on the record.

## On the record

### The leave

A leave is carried where it is said. The leaver's signature is its own
vote, the others back it as it reaches them — there is nothing to judge,
it being the leaver's own word — and a majority of the people at its
turn carries it; at a table of two, the other person's backing is that
majority. Each person backs one way out of a seat — a leave, or a boot
or claim of silence at the seat's turn — and not the other while the one
it backed can still carry. Two majorities of one table meet in somebody,
so a leave and a boot cannot both carry, and every record, the jurors'
too, names the same exit. The leaver has gone, so whoever holds the
leave carries it forward with its backing; a juror carries it on the
backing it is handed.

It is not settled in the seat's own next turn: at a table of two that
turn could never come, since every turn before it needs both people.
Where one voice per exit leaves no majority either way — two backing
the leave, two booting the seat — the turn is split and the jury rules
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
  the escrow's own — the same card by another voice — and the reopened
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
record says which. Every seat's keys name the draw they were sealed to —
the draw's event id, or none — and the draw named by the keys of the
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

A side stopped for twenty seconds (`quorumLostMs`) at a turn nobody left
can move — a seat nobody left can open, or a turn put to a jury none of
whose jurors is left — claims the game's end at that turn. The claim is
a vote in the turn's race, the third way a turn can go beside the move
and the removal; a person has one voice at a turn. A person stopped at
the same turn backs it at once; a majority of the people carries it, and
every side ends the game there (`TurnState.ended`). Where a table is
stopped at several turns of one position, every side names the lowest
seat's. The end is the last thing at its position. The verifier reads a
record ending with it as a game ended — not complete, nobody rated —
and turns down one that goes on past it, lacks its majority, or has it
claimed by somebody not at the table or at another turn
(`ended_on_record_test.dart`).

A voice already given at the turn waits for the end the rest carry and
takes it with them. A side that has seen a departed seat's hand open, and
so would work its move out, holds at the turn while the end can still
carry, and lets go once the rest are known to stand past it. A side that
has ended the game for itself says nothing more, and is not a vote still
to come.

A seat's piece holders are the custodians its keys named — including a
table of four people, whose hands are sealed to no draw but are still
escrowed to the jury (`quorum_lost_test.dart`).

## Decided here

One transition is still decided by each side for itself: **the game's
end for a lost quorum where no majority can be had.** That is a turn
split between a card and a boot with the jury gone and every voice
spent, or the last person at a table of two hearing too little of the
table. Nothing can go on the record without a majority or a jury, so
the side ends the game for itself. Its record stops at the turn, a
prefix of the table's. The rule standing in for a record is the two
minutes a side that hears too little of the table waits before ending.

## The clocks that stay

Putting transitions on the record removes guessing rules, not clocks.
The clocks that stay are of three kinds:

- **Pacing:** when to say something again — heartbeats, repeats of an
  unsettled action, carrying a peer forward, catch-up budgets, top-up
  and release repeats, how often a jury is proposed. None decides a
  state.
- **Noticing absence:** two minutes of silence from a person, half a
  minute from a juror, "heard lately" for who is here, how long a
  juror's position may stand still before it counts as stopped rather
  than catching up, and half a minute without hearing an appeal before
  a juror takes it as no longer standing — the juror's own way of
  noticing it has lost the table. Nothing but time tells gone from
  slow.
- **Deadlines on someone present:** a person's grace and bank, and a
  held seat's 15 s and 40 s. These are rules of the game, like a chess
  clock.

The deadlines, the silences that count as absence and the lost-quorum
wait are the table's, not each side's: the starter's remote config
chooses them and the signed start event carries them (`TableTiming`),
so every side and every juror times the same table by the same clocks.
Pacing is each device's own. Each clock *proposes* a transition; the
table settles it on the record.

## How it is checked

The structure checker reads every side against these machines during a
run and at its end, reporting waits stuck and sides apart. What counts
is what is still read at the end among sides still online; mid-run, an
event in flight is ordinary.

```
cd packages/table
dart run tool/chaos.dart --seeds 250 --sealed 14 --structure
dart run tool/chaos.dart --seeds 100 --sealed 14 --jurors 9 --sweep
dart run tool/chaos.dart --seeds 150 --sealed 6 --jurors 9 --sweep --twins
dart run tool/explore.dart --scenario topup --structure
```

The chaos walk (`sim/chaos_walk.dart`) throws random faults at simulated
tables; `--jurors 9` draws from more strangers than a jury, and
`--sweep` lets each juror go once it has served, as the duty does, and
summons it again later; `--twins` takes jurors' and seated players'
accounts up on new devices as it walks. It fails a seed on any broken
invariant, on two devices of one account at the table at once, on a jury
drawn from an account seated at it, on a table left stopped where nobody
up could move it, on sides still apart on the escrow once the faults
have stopped and the network has healed (sides that ended the game for
themselves aside), and on any two records — the people's and every
juror's that followed the table — naming different exits for one seat.
The explorer (`tool/explore.dart`, with scenarios `deal`, `two`,
`leave`, `summons` and `topup`) replays a short sealed game once per
event, peer and change — the first copy lost, or every copy late — and
holds each run to what the table owes.

With every transition above on the record, nothing stuck and nothing
apart is read at the end among sides still playing, except where one
side ended the game for itself (above, "Decided here").
