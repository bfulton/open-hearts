# 07 — The table's states

Every table state, every way out of it, and who can take each one.
`packages/table/lib/src/model.dart` is the same thing as code, and the
simulator reads every side against it
(`packages/table/lib/src/sim/structure.dart`).

The table works well enough. It is a pile of rules that has
been grown one bug at a time, and a growing share of those rules are
clocks: a device waits a few seconds, then assumes something about
what another device decided. A state machine that is written down says
instead which states exist, which transitions leave each one, and what
decides each transition — and so which of those clocks are rules of the
game and which are guesses standing in for a transition nobody
records.

## How a transition is decided

Every transition below is one of three kinds.

- **On the record.** A signed event, settled the way a turn is: backed
  by a majority of the people at the table, or ruled on by the jury.
  Every side ends up holding the same event. A side that falls behind
  is carried forward to it.
- **From the record.** A function of events already on the record,
  which every side works out alike. A bot seat nobody holds plays this
  way: its move is computed, not said.
- **Here.** Each side decides it for itself, from its own clock or from
  whom it happens to hear. Nothing in the record says so. Two sides can
  decide it differently, and a side that joins later can only guess.

The first two cannot leave two sides in different states for good;
the third can, and has. That is the whole of this document's argument.

## The machines

### A turn

```
open ──action──▶ acting ──majority──▶ settledByAction
  │                │
  │ claim          │ claim (a boot, or silence)
  ▼                ▼
contested ──majority for the action──▶ settledByAction
  │   └──majority for the removal──▶ settledByRemoval
  └──neither can reach one──▶ split ──the jury's ruling──▶ either of those
open ──nothing said, everyone works it out──▶ settledSilently
contested, split ──the escrow carried at a held seat──▶ acting or open
```

| From | To | Decided | Who can move it |
|---|---|---|---|
| open | acting | on the record | the seat's actor: its person; a held seat's juror; once the record gives a held seat to the escrow, a juror of the hand with its key — the first still heard, the seat's own juror last |
| open, acting | contested | on the record | any person at the table: a boot when the clock runs out, a claim of absence after two minutes' silence; at a held seat, a claim for the escrow when its juror is out |
| acting, contested | settledByAction | on the record | the people who have not backed the action |
| contested | settledByRemoval | on the record | the people who have not backed the removal |
| contested | split | from the record | nobody: it is what the backing adds up to |
| split | settled | on the record | the jury |
| contested, split | acting, open | on the record | the escrow carried at a held seat, by the people or the jury: the turn is the escrow's, keeping a move already said for the seat (acting) or waiting for one (open) — and at an audit, keeping nothing |
| open | settledSilently | from the record | nobody — worked out by every side. For a bot seat nobody holds, its move. For the audit of a held seat the record gave to the escrow, from its pieces |

### A seat

`human`, until `left` (their own signed leave), `booted` (a boot
carried at their turn) or `absent` (a claim of silence carried by the
people or by a verdict). A `bot` seat is a bot from the start. A seat
never comes back.

| From | To | Decided |
|---|---|---|
| human | booted, absent | on the record: votes in the seat's own turn, settled as it is |
| human | left | **here**, where it crosses a boot |

A leave needs nobody's agreement. It takes effect at the turn its
author put it at, on every side that has not already removed the seat
some other way. So when a leave and a boot cross, which way the seat
left, and at which turn, depends on which arrived first. The cross
happens when the leave reaches some sides only after the rest have
booted the seat for its silence.

### A held bot seat, for one hand

`held` by its juror → `escrowed`, played from then on by a juror
holding a piece of it. **On the record.** A person at the table claims
the seat for the escrow at the seat's own turn when the juror has not
been heard from for half a minute, or has had the turn in front of it
for too long: 3 s for a play or a pass, 10 s for a deal step or its
audit. The clock starts once the juror is heard at the hand, and does
not run while this side is behind the table. The claim is carried as a
boot is, by a majority of the people or by the jury; the clocks only
propose it. Until this step it was decided **here**, each side giving
the seat up for itself (below, "The escrow on the record").

### A hand

```
awaitingJury ──a jury that holds the bot seats (or none, at 40 s)──▶ dealing
dealing ──declarations in──▶ passing ──every pass──▶ playing
   │  │                        (straight to playing on a hold hand)
   │  └──nobody declared the lead card──▶ opening ──audits in──▶ givenUp
   └──a held seat given up with steps still owed──▶ abandoned
playing ──last trick──▶ auditing ──every audit──▶ over
```

| From | To | Decided |
|---|---|---|
| awaitingJury | dealing | on the record — every seat's keys name the draw they are sealed to, and the hand's is the one the first person to key it named, lowest seat first: none where that person dealt the bot seats in the open, at 40 s without a jury able to hold them |
| dealing | passing, playing, opening | from the record |
| dealing | abandoned | from the record — follows from the escrow of a held seat that still owed a step, which a side behind is carried to; the verifier asks for it |
| passing | playing | from the record |
| playing | auditing (sealed), over (seeded) | from the record |
| auditing | over | from the record — every audit in, and the audit of a seat the record gave to the escrow closes silently from its pieces |
| opening | givenUp | from the record |

A seeded table's hand starts at passing or playing and ends at over.

### The table

`playing`; `pausedForJury`, `pausedForPeers` or `pausedForDeal` while it
says what it is waiting for; `finished`; `failed`. A pause is a
reading of the hand's and turns' states, not a state of its own.
`failed` is **decided here**, each side ending the game for itself.
A side ends it once it has been stopped for twenty seconds at a turn
nobody left can move: a seat nobody left can open, or a turn put to a
jury none of whose jurors is left to rule. It must also hear most of
the table, or else have heard nothing for two minutes from everyone
it cannot hear, the jury included. It says so, and the others hear
it: a person stopped at such a turn ends with it, and a juror stops
once every person it still hears has ended.

## What each waiting state waits for

A side that is waiting names what for, and who can end it
(`TableClient.waits`):

| Wait | Who can end it |
|---|---|
| a seat's move | its person, or the people at the table by a boot or a claim of silence; a held seat's juror, or the people by a claim for the escrow; once the record gives it to the escrow, any juror of the hand with its key |
| backing for an action or a claim this side holds | the people at the table who have not given theirs; once a silent voter has split the turn, the hand's jurors |
| the jury's ruling on a split turn | the hand's jurors |
| a departed or escrowed seat's secret | enough of those holding a piece of it: a held seat's own juror or a quorum of the jurors with a piece; for a departed person's seat, one of the jury the deal was sealed to beside a person's piece |
| a jury that can hold the bot seats | somebody outside the table, not yet drawn |

A bot seat nobody holds is never waited on. Every side works its move
out. The move waits only if the seat's cards are not open here yet,
and then it is waiting for the seat's secret.

## Stuck

A wait is **covered** when someone who can end it is up, and either
holds what ends it or is on the way to it:

- the move, or the seat's removal, has been made or is owed;
- the backing has been given, and is repeated until the turn settles;
- a juror is up to rule a turn the voters cannot carry;
- the turn is decided on the record, which a side behind is carried to;
- enough of the seat's pieces to open it are held by sides that are
  up, and a side that has given the seat up itself is saying its
  piece.

A side is **stuck** when a wait of its is one of the following. This
is a fact about states, not about how long anything has taken.

- **on nobody**: nobody up can end it. The side may be paused, saying
  why it waits, and still wait for good;
- **left behind**: everyone up who could end it has left it behind in
  a way no rule brings back. They have moved past its hand without
  deciding it, closed it with nothing said, never given up the seat
  whose pieces the side wants, or finished the game without it;
- **in a cycle**: the sides that could end it are waiting on each
  other at it, and none of them has a way out.

Separately, sides are **apart** when they disagree on something each
side decides for itself:
- a held seat escrowed at one side and not another;
- a hand abandoned at one side and not another;
- a deal sealed to different jury draws;
- the game failed at one side and not another;
- a turn closed silently at one side and decided on the record at
  another;
- a person removed at different turns at two sides, or removed at
  one and still seated at another that has moved past the hand of
  the removal.

Being apart is not stuck in itself, but both of the bugs below became
stuck through it.

Checked against two bugs found and fixed just before this was
written, with each fix taken out:

- **The fork in the deal-step clock.** A person who lost one copy of a
  juror's keys abandoned the hand alone. The checker reads *apart*
  at the second it happens: the hand abandoned there, still being
  dealt everywhere else. Three seconds later the others boot that
  person at the shuffle they are owed, and the checker reads *apart*
  on the seat: the boot is on the record, and the person who left
  will never take it. Once the others finish the game, the person who
  left is waiting on people and jurors who have nothing more to say.
  That is *left behind*, and it is still read when the run ends. The
  explorer judges a run only at its five-minute horizon, and needed
  that long to call the same run broken.
- **One audit, two records.** Here the checker says *apart*: the seat's
  audit was closed silently at one person and decided on the record at
  the other. That is where the two records came to differ.

With the fixes in, neither is read. What is still read in the second
case is the escrow disagreement the scenario sets up on purpose. It was
the per-device decision the next step put on the record (below, "The
escrow on the record").

## Decided here

Seven transitions when this was written. The escrow is on the record
now, and the abandoned hand and the escrowed seat's audit follow from
it (below, "The escrow on the record"); so are the draw a deal is
sealed to and, with it, the fall-back to bot seats in the open (below,
"The draw on the record"). What is still decided here, and the rules
that exist only because it is not on the record:

| Decided here | What it has cost | Rules standing in for a record |
|---|---|---|
| The game ended for a lost quorum | the people ending it up to five seconds apart, and the last juror not told (below). It is said now: a juror stops on hearing it, and a person stopped at the same turn ends with it | the two minutes a side that hears too little of the table waits |
| Which way a seat left, where a leave crosses a boot | the people and the jurors holding different records to the end of a game (below) | `_onLeave` passing over a leave for a seat already removed |

The five rows that are gone read:

- a held seat given to the escrow, which had cost two jurors playing
  the same card for one seat, settled only by the jury's rule for two
  voices; one audit on two records (since fixed); and sides apart on
  it for the rest of a hand;
- a hand abandoned in its deal, which had cost a player abandoning
  alone (the fork above, since fixed), newcomers replaying a hand the
  table had left, and jurors cut off abandoning a hand the table
  played;
- an escrowed seat's audit closed silently, which had cost the audit
  case above;
- the draw a deal is sealed to, which had cost holders read from
  different juries while a draw was in flight, for two seconds in most
  top-up runs, and one hand sealed to two draws, where a draw proposed
  from an earlier place arrived after a step had settled on a later
  one (sealed chaos seed 2 with nine strangers to draw from,
  `tool/chaos.dart --jurors 9`);
- bot seats dealt in the open after forty seconds without a jury able
  to hold them, which had not been seen to cost anything, and would
  have dealt one hand two ways at two sides judging the forty seconds
  differently.

The rules that stood in for them were `_holderStillAudits`,
`_auditLeftBehind`, `_dealLeftBehind` and the verifier's
`heldSeatOwes`; and for the draw, the two seconds a juror waited for
it to stand still (`_juryFirmMs`) and a juror brought on after a
hand's first jury making no keys for it. All gone. `_refixHolders`
stays, following the record now rather than the latest draw heard. The two-voices rule stays, for a different
reason: a move by the seat's juror that lands after the escrow is as
good as the escrow's own. So does the ten-second cap in `_arriving`,
which was listed with the abandoned hand: it tells a juror that has
stopped from one still catching up, which is noticing absence, one of
the clocks that stay (below).

## The clocks that stay

Taking these transitions onto the record removes the guessing rules.
It does not remove every clock, and should not. The clocks that stay
are of three kinds:

- **Pacing:** when to say something again. This covers heartbeats,
  repeats of an unsettled action, carrying a peer forward, catch-up
  budgets, top-up and release repeats, and how often a jury is
  proposed. None of them decides a state.
- **Noticing absence:** two minutes of silence from a person, half a
  minute from a juror, and "heard lately" for who is here. Nothing but
  time tells gone from slow.
- **Deadlines on someone present:** a person's grace and bank, and a
  held seat's 3 s and 10 s. These are rules of the game, like a chess
  clock.

Each of these *proposes* a transition, and the table settles it on
the record — as a boot has always worked. The same would hold for the
twenty seconds of a lost quorum.

## Measured

The checker reads every side at once: every five seconds of a chaos
walk, every second of an explorer run, and once more when a run ends.
Most of what it reads mid-run passes, such as an event in flight or a
wait on someone gone before anyone has noticed. What counts is what
is still read when a run ends, and whether the sides that disagree
are both online. A juror that has stopped serving is not read: its
host closes it (`JurorDuty`), though the simulator's never does.

Measured twice: first as the table was, then with the game ending
wherever the jury is gone and nobody is left to draw (below, and doc
04, "When quorum is lost anyway"). A third time, with the escrow on
the record, is under "The escrow on the record".

**The chaos walk**, 250 seeds and 14 sealed. Every invariant held,
both times; the second time under a walk that also fails any seed
left stopped where nobody up could move the table.

| Read | Walks | Still read at the end, first | Now |
|---|---|---|---|
| stuck on nobody | 6 | 4 | 0 |
| apart on the escrow | 8 | 1 | 0 |
| apart on a seat | 1 | 1 | 0, for the jurors holding the other exit stop serving |
| apart on the game's end | 1 | 0 | 0 |

Nothing was left behind, and nothing was read in a cycle. No sides
were apart on a turn, on a hand's outcome, or on the draw a deal was
sealed to.

**The explorer**, each run losing or holding back one copy of one
message. Every run held, both times.

| Scenario | Runs | Read |
|---|---|---|
| deal | 869 | apart on the escrow in 11, for the rest of the hand |
| two | 1,387 | apart on the escrow in 3 |
| leave | 1,343 | apart on the escrow in 1 |
| summons | 869 | apart on the escrow in 11 |
| topup, played to the end of the hand | 4,208 | apart on the draw in 3,830, for about two seconds each; apart on the escrow in 14, and in 13 still at the end. At first also apart on the hand's outcome in every run, always with a juror cut off for good (below) |

What the readings are:

- **Stuck on nobody.** In every one the jury is gone and nobody is
  left to draw, since the walk's table has exactly four jurors. Each
  side is waiting on something only a juror can give. Four walks were
  stuck for good; each now ends the game.
  - Seeds 1 and 72 are unsealed two-person tables, each with a turn
    only the jury can settle. In seed 1 a play is met by a boot, one
    vote each. In seed 72 it is a claim of silence against the only
    other person. Both tables paused for the jury and stayed paused.
    In seed 1 the person whose play it was then left. The leave is
    placed after the turn it has an action in, so it waited behind
    that turn.
  - In sealed seed 8, one of two people and three of four jurors go.
    Nobody still up can open a seat's secret. The person left heard
    too little of the table to end the game for a lost quorum, and
    stayed paused.
  - In sealed seed 2 the people did end the game for a lost quorum.
    The last juror was never told, and waited at the seat. Its host
    would have closed it after five minutes of hearing nobody.

  Sealed seeds 1 and 3 are the same case, ended for a lost quorum
  from the start.
- **Apart on the escrow.** One side gives a held seat to the escrow
  and another does not: the seat's juror is out of time as one side
  sees it and not as the other does. In the first case the explorer
  found, a copy of the seat's play was lost on the way to one juror,
  which gave the seat up alone. Nothing brings the sides back
  together before the hand ends.
- **Apart on a hand's outcome.** In the topup scenario, two jurors cut
  off for good give up hand 0 thirty-one seconds in, while the table
  deals the hand and plays it out. If those jurors came back, they
  would hold as abandoned a hand the record shows played. They stop
  serving once they have given it up, so a host closes them, and the
  second measurement does not read them.
- **Apart on the draw.** In the topup scenario the sides read a hand's
  deal as sealed to different draws for about two seconds, then agree
  on one.
- **Apart on a seat.** Seed 43: the leave and the boot described
  under *A seat*. The people's records and the jurors' records hold
  different exits for as long as those jurors serve. The walk compares
  only the people's records, so it passed.
- **Apart on the game's end.** Sealed seed 2: the two people end the
  game for a lost quorum no more than five seconds apart.

The ending found two faults of its own in the chaos walk before it
held, each now a test (`quorum_lost_test.dart`):
- **The pause alone.** In seed 3, a pause for the jury put up while
  two people were cut off from each other outlasted their being cut
  off. One of them ended the game on it, though the turn was theirs to
  settle again.
- **A jury cut off, not gone.** In seed 8, a juror cut off from the
  last person for a minute had already ruled, and the person ended the
  game before its ruling arrived.

## The escrow on the record

The first of the seven, built. A person at the table whose clocks say
a held seat's juror is out — not heard from for half a minute, or past
its time on the seat's turn — claims the seat for the escrow at that
turn, with an `escrow` event. The claim is a vote in the turn's race,
as a boot is at a person's seat. A majority of the people carries it;
where they split between the juror's move and the claim, the jury
rules by the juror's presence to it. Every record holds the claim that
carried, at the turn it was made. From there the seat is the escrow's
for the rest of the hand, played by the first of the hand's jurors
still heard, the seat's own juror last. A deal step still owed gives
the hand up. The audit closes from the seat's pieces with nothing said.
The verifier holds a record to the same
(`packages/table/test/escrow_on_record_test.dart`).

Building it turned up these, each now a test:

- **A move dropped at the reopen.** The escrow opens the turn again,
  and at first the reopen dropped whatever had been said for the
  seat. A juror woken from a doze sent the card it had said while
  asleep. The people, past the escrow, carried it, since a juror's
  move is as good after the escrow as a custodian's. The juror had
  dropped the card itself, and took every later copy of it, and of
  the witnesses to it, for one already seen. It sat at that turn
  while the table dealt the next hand (`audit_left_behind_test.dart`).
  The reopen keeps the moves now, and who backed them; only a side
  whose voice went to the escrow votes again.
- **A draw carried for a hand already given up.** The escrow and a
  jury drawn again without the silent juror each take a round trip,
  and a side can carry them in either order. One that gave the hand
  up first and then carried the draw rebuilt its deal from it: the
  next hand's deal, sealed to the old hand's jury. It never met the
  rest of the table again (`undealt_hand_test.dart`). A jury carried
  for a hand the table has left rebuilds nothing now.
- **The escrowed seat's own audit.** Its juror still said it, and
  after the escrow any juror of the hand may move the seat. Taken at
  a side still waiting for the pieces, it could carry there while the
  rest closed the turn from the pieces. The audit of an escrowed seat
  is nobody's move now: not said, not taken, and dropped from the turn
  if the escrow finds it there.
- **A ruling for a held seat's step, dropped.** With the escrow on the
  record the people can split on a held seat's deal step or its
  audit. The jury ruled for the step, and every side dropped the
  ruling, taking only a card from the jury; the turn would have
  waited for good.
- **An escrow heard too late to count.** A turn can hold both the
  escrow and a move after it. A side that heard the backing for the
  move before the claims settled the move, then dropped the claims as
  late, and held the seat as its juror's for the rest of the hand:
  four jurors topped up mid-hand, in the explorer's topup scenario,
  would have taken none of the escrow's moves for it. Claims, their
  witnesses and a ruling for the escrow are now taken at a play or a
  pass already settled by the move, and the escrow is recorded beside
  it.
- **A deal built again, out of order.** A juror topped up mid-hand
  reads the redraw before the draw the deal was sealed to, and builds
  its deal again when that draw comes. The rebuild took up what had
  been held back for the deal before putting back the steps already
  settled, so one held-back seat's keys went into a session that had
  none of the others'. The round of keys closed with the deal still
  at its keys, and nothing asked it to go on: the juror sat at the
  hand's keys to the end of the game (`deal_rebuilt_test.dart`). This
  one is older than the escrow on the record; the traffic of the
  escrow moved the timing onto it.
- **The last hand's audits unchecked.** A hand's four audits share a
  position, and a removal sorts first at a position, so an escrow
  claimed at an audit comes before the audits. The verifier took each
  hand's removals before its audits except the last hand's, where it
  stopped at the claim and checked neither it nor the audits. It also
  took a seat audited twice, and a record that went on past the end
  of the game.

The chaos walk now fails a seed that ends, once the faults have
stopped and the network has healed, with sides still playing apart on
the escrow. Sides that have ended the game for a lost quorum are left
out: one can carry an escrow the other never hears of, over a game
that is over and unscored (sealed seed 2).

Measured again with the same walk and explorer as above, on the code
with all of this in:

| Where | Before: apart on the escrow, still at the end among sides online | Now |
|---|---|---|
| chaos walk, 250 seeds and 14 sealed | 8 walks, none at the end | 1 walk, 1 at the end: sealed seed 2, both people having ended the game |
| explorer, deal (869 runs) | 11 runs, 11 at the end | 2 runs, none at the end |
| explorer, two (1,387) | 3, 3 | 2, none |
| explorer, leave (1,343) | 1, 1 | none |
| explorer, summons (869) | 11, 11 | 2, none |
| explorer, topup (4,208) | 14, 13 | 11, none: in each the side still apart is one of the two jurors the scenario takes offline for good |

Every walk and every run held. The rest of what the walk reads is as
before: stuck on nobody in six walks and in none at the end, apart on a
seat in seed 43 and on the game's end in sealed seed 2, neither at the
end. What is read now is an escrow in flight: claimed at a turn and
carried at some sides a moment before the rest.

And one rule was tried and taken out again: keeping the seat's own
juror off the jury's ruling on its own seat, since to itself it is
always there. The foreman never holds a seat, so the seat's juror
rules only when the jurors before it cannot — in practice, when they
lack the move — and its ruling is for a real move, which the verifier
checks against the policy. Kept off, it left such a turn with nobody
able to rule.

## The abandoned hand and the escrowed audit

The second of the seven. With the escrow on the record both follow
from it, and the rules that worked them out without it are gone: a
side still in a hand's deal, or at a bot seat's audit, five seconds
after most of the table was heard at a later hand, settled it as the
table must have (`_dealLeftBehind`, `_auditLeftBehind`); and the
verifier took a deal short of a held seat's step for one given up
(`heldSeatOwes`). The verifier now asks for the escrow that gave the
hand up, at one of that seat's deal steps with a step still owed.

A side behind is carried to the escrow like any removal, and taking
the rules out found the one place it was not: a hand given up at a
held seat's first shuffle. Nothing settles at the turn such a hand
stops at, and what a side behind is sent from a turn is what settled
there — so a person who missed the escrow there, and asked from that
turn, was sent nothing. It waited while the table dealt the next hand,
and was put out at that hand's keys (`undealt_hand_test.dart`, with
the bots seated first so that a held seat shuffles first). From any
turn of a hand given up in its deal, the hand's removals are sent now.

Measured again without the rules, with the same walk and explorer:
every walk and every run held, and what is read is what was read with
them — nothing stuck and nothing apart at the end among sides still
playing, in the walk or in any scenario.

## The draw on the record

The fourth of the seven, taken ahead of the third: the chaos walk
drawing from nine strangers rather than four found it failing
(`tool/chaos.dart --jurors 9`), in sealed seed 2, and in seed 3 once
jurors were let go of and summoned again, as the duty does
(`--sweep`).

A hand's bot seats are held by the draw its deal is sealed to, and each
side read that for itself: the first draw of the hand it had heard, by
where each was proposed, with two seconds for a late draw to arrive
and a rebuild of the deal when one did. Where a draw was proposed is
its proposer's own place, though, not a time. A redraw of three
strangers, too few to hold anything, proposed from the first person's
place after the table had dealt to a draw of six from the second
person's, read as the hand's first. Sides then dealt the bots in the
open or to the six by what they had heard; a juror had keyed a seat,
which settles and does not come back; and the hand stopped at a seat
whose keys nobody would make.

Now the record says it. Every seat's keys name the draw they were
sealed to — the draw's event id, or none — and the draw named by the
keys of the first person to key the hand is the hand's, at every side
and at the verifier: lowest seat first, passing over a person removed
at their keys or gone before them. A person's keys name a draw carried
where they are taken that can hold every bot seat, or none. A hand
nobody at the table can key — every seat a bot's, a leaver's client
looking on — is sealed to none. Until the first person's keys have
settled at a side:

- a held seat's juror makes no keys, and its time for them has not
  started;
- no side takes a held seat's keys, and afterwards takes them only
  naming the same draw, from the juror that draw names for the seat;
- no bot seat's keys are settled with nothing said. Whether the jury
  holds a seat is the draw's to say, and a side that had dealt its bots
  in the open for want of a jury, and settled their keys, could not
  take that back when the record sealed the hand to a draw: it sat at
  the keys of a seat whose holder it now knew;
- nobody claims a held seat for the escrow at its keys, and a claim
  that comes is kept for when the record has said: a claim names the
  seat, not the juror, so one made against a guessed holder counts
  against the real one.

Building it found one more thing, and it is a test now: keys that
arrive before the draw they name has been carried at a side were kept
but never looked at again. Held-back steps were taken up when a draw
was proposed, not when it carried, so every juror summoned a moment
after its table's jury carried sat at the keys, and each of its seats
went to the escrow (`packages/table/test/sealed_to_draw_test.dart`).

Measuring it found the same wait a level up. In the explorer's topup
scenario with no fault at all, the jurors a redraw brought in read the
redraw as the hand's draw for eight seconds, where the code before
this read the sides apart on the draw for two. They were waiting for
the hand's first draw to be carried to them. Every carry says every
jury, so the table had said that one again, to the sides already
there, a second before the newcomers were; an event goes once in
eight seconds whoever is asking; and keys naming a draw not carried
are not taken, so they sat at the keys until it came. A summons now
carries the hand's draws, each with its witnesses, and the newcomers
read the table's draw from the moment they are summoned — and seal
six seconds sooner (`sealed_to_draw_test.dart`, doc 04, "On the
wire").

With the draws in hand the jury deals a little sooner, and that moved
a timing a test had been leaning on into a gap in the escrow. A held
seat's juror played its card and went, the card reaching three of the
jury and neither person. The people gave the seat to the escrow, as
they should. The escrow keeps a move said at its turn, since a juror
of the hand's is good after it; so the custodian whose place it was to
say the seat's move held one already and said nothing, the move's
author was gone, and a juror says only its own moves again. The hand
stopped at the seat for good (`quiet_holder_test.dart`). The custodian
that speaks for a given-up seat now says again what the seat's turn
holds, as the seat's own juror would have
(`escrow_on_record_test.dart`).

The escrow's custodians are the same story one level down, and the
nine-stranger walk found that too. A held seat's pieces are indexed by
each custodian's place in a list that starts with the jury the deal
was sealed to and grows as the jury is topped up; the list started
from the first draw by order, and a held seat's keys sealed their
pieces to every draw heard by then, sorted, which is another order
again. Both read the record's draw now, and a juror's keys seal to the
list itself. And the verifier never grew the list at all: a piece
released by a juror brought on in a top-up counted for nobody, and a
seat the table had opened from such a piece and one other did not
open for it (sealed seed 10, `packages/table/test/top_up_test.dart`).
It grows a held seat's custodians as the table does, in the juries'
own order.

A test of the top-up after a seat's keys found one more, older than
any of this. A newcomer's share is made by the first two custodians
still heard, and the seat's own juror is a custodian with no share of
its seat: it holds the whole secret, and its session had kept neither
its own share nor the list of who the others went to. Where it was one
of the two, the newcomer was sent one part of every pair and never the
other, for as long as the hand lasted. It keeps both now
(`packages/deal`, `myKeys`).

Which leaves one thing decided by arrival: the table grows the list as
each redraw carries, and two redraws of one hand carried in the other
order at two sides would give their newcomers different places. The
juries' own order and the order they carry in have agreed in every
walk and run so far; it goes on the list below.

The fall-back to bot seats in the open comes with the draw. A person
whose table has had no jury able to hold the bot seats for forty
seconds deals without one, and its keys then name no draw; where those
are the first person's keys, that is the hand's, and every side deals
the bots in the open, a side that had a jury by then included. Two
sides judging the forty seconds differently now deal one hand one way.

It costs one round trip in the deal. A juror's keys now wait for the
first person's to settle, where the two seconds it used to wait ran
beside the people's own steps: 6.90 s to the first card on average
over twenty seeded hands at a jury of ten, against 6.60 before
(`tool/time_to_deal.dart --seeds 20`).

## Next

The step after this document puts the seven transitions on the
record, in this order:
1. the escrow — done (above);
2. the abandoned hand and the escrowed audit — done (above);
3. the lost-quorum ending;
4. the jury draw a deal is sealed to, read in record order rather than
   arrival order — done (above, "The draw on the record"), ahead of
   the third, since a walk found it failing;
5. the open-bots fall-back — done with the fourth: the first person's
   keys naming no draw are the fall-back, on the record;
6. the leave, settled in the seat's turn as a boot is, so that a leave
   and a boot at one seat are one race with one winner;
7. found on the way, and decided the same way as the draw was: the
   order a hand's redraws add their newcomers to the escrow's
   custodians in (above, "The draw on the record").

Each would be settled the way a boot is, and each would remove the
guessing rules it stands behind. The checker above goes from
measuring to asserting as each lands.

The measurement also found states with no way out once the jury is
gone and nobody is left to draw:
- a turn only the jury can settle;
- a seat's secret that nobody still up can open, at a side that hears
  too little of the table to end the game;
- a juror following a game the people had ended, never told, until
  its host gave up on hearing nobody.

Each now ends the game, and the ending is said ([doc
04](04-live-play.md), "When quorum is lost anyway"). The chaos walk
now fails a seed left stopped where nobody up could move the table.
