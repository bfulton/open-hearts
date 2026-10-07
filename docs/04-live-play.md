# 04 — Live play

How the multiplayer game works: getting to a table, how four devices
agree on every turn with nobody in charge, what happens when people
leave, and the jury of strangers that covers what the players cannot.
How the bytes move is [doc 02](02-multiplayer.md); how the deal stays
honest is [doc 03](03-fair-deal.md); every state and transition, named,
is [doc 07](07-states.md).

Solo play is free; live play is a subscription, so everyone at a live
table holds a licence and sits as an account, on one device at a time
([doc 06](06-service.md), and [Identity](#identity) below). The protocol
is `packages/table` — chiefly `client.dart`, `jury.dart`,
`juror_duty.dart`, `matching.dart` and `record.dart`, the verifier —
driven by `app/lib/live_controller.dart` and `app/lib/net/`.

## Getting to a table

There is one screen before a game. The profile behind its top-right
icon holds a name and an avatar (an icon on a colour, or a 64-pixel
picture), kept on the device and, for a subscriber, with the account,
so every device of the account shows the same
([doc 06](06-service.md#the-accounts-profile)); a picture travels once,
as a stored event. The live area says which game is asked for — fifty points or a
hundred, rated or unrated — and *Play live* shows how many devices are
online.

### Matchmaking

There is no matchmaker (`packages/table/lib/src/matching.dart`). Players
who want a game say so on the relay every couple of seconds, in a pool
whose tag names the target score and whether it is rated, with their
rating, pace, how long they have waited and their licence. Time is cut
into rounds of five seconds; in each, the lowest key present acts as
host, runs the seating rule over everyone it has heard from, and
publishes one signed start event per table. If the host says nothing,
the next key steps in: a host can waste five seconds but cannot forge a
play. A device entering a pool reads the last minute of seatings.

The rule:

- whoever has waited through a round is seated first, then the rest at
  random;
- a table is four ratings within a window that widens a hundred points
  for every round the first of them has waited, and four paces within a
  window that widens three seconds a round;
- once someone has waited ten seconds without a full table, they get
  one, with bots at their own rating in the empty seats.

Two hosts with different views may seat someone twice. Everyone takes
the seating with the lower table id, and the other table's empty seat is
booted at its first turn.

A seating names each seat's licence. Nobody sits at one where a seat's
licence is not the service's word for that seat's key, or where an
account sits twice, and a waiter without one is not seated by anyone.

**Pace**, seconds a card, is matched because three fast players and one
slow one make a bad evening for all four. It is a device's own account
of itself (`pace.dart`, `app/lib/pace_store.dart`): the record carries
no clock, so no two peers could agree on how long a seat took, but a
device can time its own turns exactly. It decides who you sit with and
nothing else; a player who lies sits with people at a speed they do not
play. A turn longer than the table would ever wait is not counted.

### Friends' rooms

*Play friends* opens a room at a code of eight characters from
`Random.secure()`, from an alphabet with no lookalikes; the code is all
that keeps a stranger out. Nobody types it: the room offers *Share the
link*, and opening the link lands in the room. On the web the room's
address is in the address bar, so a refresh comes back.

Nobody hosts a room (`app/lib/net/room.dart`). Everyone at a code says
so on the relay every two seconds; whoever has been heard lately is the
table, in arrival order, and the lowest key present leads. The leader
starts the table ten seconds after the last arrival, at once at four, or
on *Start now*. A start counts only from someone present and only if
recent, since the relay keeps them and codes get reused.

The signed start event names everything the seats must agree on — the
seats with their licences, the target score, whether it is rated, the
table's clocks — since seats that disagreed on any of them would fork.
A room's members say their licences in their beats, and a start whose
seats do not check out is not sat at.

## Bots

**A bot seat says it is a bot**, where a person's name would go. Most
tables at low liquidity are one person and three bots, and the app does
not disguise that with plausible usernames.

**The bots are famous lovers** — Romeo and Juliet, Cyrano and Roxane,
Westley and Buttercup, Orpheus and Eurydice, Casanova, Don Juan and the
rest of `packages/engine/lib/src/persona.dart`. Each is a temperament:
one policy with a few thresholds moved, so Romeo cannot hold a queen and
Don Juan runs at the moon on a hand the others would not. Every setting
is measured to be a choice a strong player might make: a tournament test
seats random fours from the roster and fails if any persona falls
behind, and `packages/engine/tool/blunders.dart` looks for
self-destructive plays in bot-versus-bot games.

**Every character comes at nine strengths** (`Persona.at`), so a person
is seated with bots near their own rating. The top rung is the whole
policy; each rung down removes one thing a player learns, in about the
order people learn it. Rung 0 passes its three highest cards, leads its
lowest, follows with its lowest and throws its highest when void — the
rules and nothing else. Then, one rung at a time: duck as high as you
can; last to play and taking the trick anyway, throw the top card; void,
throw the queen and hearts first; pass by shape; lead small spades to
flush the queen; void, throw a heart before a side card; throw the top
club on the first trick; and at the top, run at the moon.

Every rung defends against the moon: a bot that never did would be a
rating pump for anyone who runs at every chance.

The ladder is calibrated in the arena (`packages/table/tool/ladder.dart`,
twenty thousand tables of random fours from nearby rungs, games to
fifty). It spans about 170 points, and those are the priors a bot starts
from (`Persona.priors`); from there it floats on its results like
anyone. A bot's identity is its name and rung: `Westley` at the top,
`Westley/3` on rung 3.

The live view replays the record at a human pace — each bot thinks for
its persona's beat, a finished trick sits for a moment — so a person
sees every card land (`live_controller.dart`).

## Ratings

**One rule for people and bots** (`rating.dart`, `results.dart`). A
person is an account: whichever of its devices played, the rating is the
account's. A finished rated game is one Glicko rating period with three
opponents, scored pairwise by final total: the lower total wins the
pair, equal totals halve. A bot that sat down at the deal is rated like
a person, one rating per persona per rung, so any edge a person finds
against the bots is priced in rather than farmed. A bot that took over a
leaver's seat has no stake; the leaver finishes last. A rating is
provisional while its deviation is above 150.

**Results are signed and public.** At the end of a rated game every
person at the table publishes the same result — the table, the seats,
the totals, who was there from the deal and who left — signed with
their device's key, under one tag on the relay (`standings`). Each
person's line names the account and carries the licence that says the
key it sat with is one of the account's devices, so anyone folding
results checks whose it is. A result stands when a majority of the
accounts that sat down published the same one, each by the device it
sat with; a stranger's word, or the account's other device's, counts
for nothing. At a table of two that is both, so each device
waits for the relay to acknowledge its copy, and retries on a fresh
connection after five seconds, twenty and a minute while none has
(`app/lib/net/standing.dart`).

Anyone can fold every standing result, oldest first, into every rating
(`Ledger`); the app does so when it reaches the relay. Ratings began
again with accounts: the results from before, keyed by device and under
the old `results` tag, are not folded. The score sheet
of a rated game shows what it did — "1500 → 1516" — by folding the
device's own result into the ledger it holds. A rating stated in a pool
only decides who you sit with. Every live table is sealed
([doc 03](03-fair-deal.md)), so a rating rests on records anyone can
verify.

## How a table talks

The transport is a WebRTC data channel to every other person and to the
hand's jurors, with the relay as the lane behind it while somebody the
table must reach has no channel open (`MeshTransport`,
[doc 02](02-multiplayer.md)). The client says who it must reach as it
learns them (`Transport.reach`: the seats at the start, the jurors as
each jury carries). The relay list is the build's or the remote
config's — in a deployed build, one relay, ours, with the tag in the
address so a table meets in one object ([doc 08](08-own-relays.md),
`app/lib/net/relays.dart`).

A relay must read, check and sometimes store what it carries, so it gets
JSON. A channel has our code at both ends, so it gets the event as bytes
(`frame.dart`): no base64 around the deal's cryptography, no hex around
keys and signatures, no table id and no event id (recomputed from the
rest). A hand is 36% smaller than as JSON with no compressor
(`packages/table/tool/wire_breakdown.dart`). The canonical bytes
underneath are the same, so an event has the same id whichever way it
arrived.

With several relays a client listens on all, sends room beats,
presence and signalling to all, and writes each table event to the
first relay that everyone it has heard from reads (each heartbeat says
which relays its sender reads). A refused event moves on to the next
relay; when every relay refuses, the line under the felt says so
(`relays.dart`).

Events that decide something for someone else — a boot, a claim of
absence, an appeal, a verdict, a leave, a claim for the escrow — go by
every path, and so does a seat's own action the moment a boot or appeal
names it: a peer that cannot read the relay this device writes to cannot
say so. A subscription that delivers nothing for twenty-five seconds
after publishing — a device's own events should come back on it — is
taken as dead and remade.

## Turns and majorities

Hearts is turn-based, which dissolves most of what would otherwise be a
hard problem. Exactly one seat may act at a time, and the rules — not
who spoke first — say which. The one concurrent question is whether
the seat on turn is still there, and the protocol treats every turn as
exactly that question.

**A turn is a race with two sides.** On one side the seat's own action,
signed by the seat. On the other its removal: a boot, pressed once the
seat's clock has run out, or a claim of absence by a peer that has not
heard from the seat for two minutes. Every other participant backs one
side with a signature, never both, and a side wins with a **strict
majority of the participants at that turn**. Only then does the next
turn open, so nothing is ever rolled back.

**Who the majority is of** is a function of the record, not the clock:
the people who sat down, less anyone removed at that turn or earlier. A
peer that has not heard of a removal measures against a larger set,
which can only make it wait.

A peer claims or backs a removal only while it hears from a majority of
the participants; a peer that does not is the one cut off, and says so.
**This is what stops a partition becoming a fork.** Split a table of
four people 2–2 and neither half has a majority, so neither removes
anyone; both wait, and when the network heals, whoever holds unsettled
evidence repeats it. Split it 2–1 and the two proceed; the one learns it
is out when the network heals. Where no majority exists — two people,
one silent — the turn goes to the jury.

**A bot seat nobody holds needs no events**: its move is a function of
the deal and the record, which every peer computes. At a sealed table
with a jury, bot seats are held by jurors instead (below).

**The record** holds every settled turn and every departure with the
signatures that carried it, in an order every peer reaches on its own:
by hand and position, departures ahead of the actions at the same
position. Anyone can replay it against the deal (`verifyRecord`,
`record.dart`): every human action signed by its seat's key and legal,
every removal carried by the participants of its moment, every majority
checked against a set the peer could legitimately have measured against,
every bot move recomputed.

### Hearing, repeating and catching up

A peer counts as heard from when it sent something itself, or when its
own signed work first arrives at or past where the hearer stands; a
relayed copy of something already seen is not a sign of life.

Whoever said something that has not settled says it again. A heartbeat
(every five seconds) says where its sender stands, and a peer behind is
sent the turns it is missing, twelve at a time, unasked — which is also
how it learns of departures it never received. Catching up is budgeted:
the lowest key present answers first, the others only if the asker stays
behind; an event is said again at most once in eight seconds whoever
asks (`carryRepeatMs`); all of it is drawn from twenty-four events a
second. A removed seat still sending is carried only to the turn that
removed it, every ten seconds.

## Clocks

A person's clock is a bank, not a limit per card (`time_bank.dart`).
Each decision has a grace that costs nothing, and each hand a bank that
the part of a decision past its grace drains, so a player who thinks
hard over three cards is never bothered and one who takes fourteen
seconds over every card is bootable on their sixth. The deal's turns
and the audit, which a device answers by itself, have a fixed clock.
Past its grace a seat's remaining clock shows on its badge; at empty, a
*Boot* button.

A table's clocks are chosen by the device that starts it, from its
remote config ([doc 06](06-service.md)), and ride in the signed start
event (`TableTiming`, `timing.dart`): seats that disagreed about when a
boot was due would back different sides of it. A start that names none,
or one out of bounds, is the standard table everywhere. Pacing — how
often something is said again — is each device's own.

| Clock | Standard |
|---|---|
| grace per card / per pass | 6 s / 20 s |
| bank per hand | 45 s |
| deal step or audit (person) | 40 s |
| held bot seat: card or pass / deal step or audit | 15 s / 40 s |
| silence before a person counts as absent | 2 min |
| silence before a juror counts as gone | 30 s |
| closed connection: grace to come back | 20 s |
| stopped table before the game ends for a lost quorum | 20 s |

## Leaving

Strangers leave; it is the medium, not misbehaviour. A person leaving
is replaced by a bot at once, mid-hand: three people should not lose a
game because a fourth got on a train. A seat never comes back to a
person once a bot has it. There are three doors, and all produce the
same fact on the record: **seat N is out as of turn T.**

**Leave**, from the menu. Signed by the leaver and placed at the turn
they stood at; their signature is their own vote, the others back it as
it reaches them, and a majority of the people there carries it (at a
table of two, the other person's backing). Each person backs one way out
of a seat, so where a leave and a boot cross only one carries
([doc 07](07-states.md)).

**Boot.** Once a seat's bank is empty and the grace on its current
decision spent, the *Boot* button appears. It is a **trigger, not a
vote**: every peer keeps its own account of each seat's bank and
countersigns once its own clock agrees. A peer holding a signed play
for that turn rebroadcasts it instead, so a boot attempt repairs a
dropped message: a valid play for turn T voids any boot for T. The
player being booted sees their own countdown.

**Silence.** A peer that has heard nothing from a seat for two minutes
claims its absence the moment its turn is open. Two minutes is longer
than the bank a stalled seat empties, so an active table resolves
through the visible boot, and a phone that switches apps for a moment
comes back to its seat.

Silence is answered **at the seat's own turn and nowhere else**. A
silent seat still counts toward every majority meanwhile, so someone
else's contested turn can stick for want of its vote; that turn goes to
the jury. Removing a seat mid-turn would let two peers that apply the
removal at different moments settle the turn opposite ways.

A seat that is booted or falls silent sees *A bot took your seat*.

### Coming back after a reload

A device keeps everything it signed at the table and each hand's deal
secret (`journal.dart`; `app/lib/net/seat_store.dart`), written before
each event goes out. Reloaded, the app goes straight back to the table:
the new client reads its own word back before saying anything — so it
never contradicts a move or vote it already made — takes its keys from
the kept secret, and is carried forward like any peer behind.

A closed connection spends most of the silence allowance at once,
leaving twenty seconds (`reloadGraceMs`): enough for a reload, and less
than the turn's own clock, so a device really gone holds the table up no
longer than a slow one. Gone longer, the seat is removed at its next
turn, and the device that comes back is caught up to its own removal
(`packages/table/test/rejoin_test.dart`).

## The jury

Two things cannot be settled by the players alone. At **two people**, a
silent player leaves the other with one vote of two — no majority, and
from inside, a rage quit and a partition look the same. And wherever a
**seat is a bot** at a sealed table, thirteen secret cards need a device
to hold and play them that is not a player's. Both need a party with no
stake in the table.

So every hand draws a **jury**: six strangers (`jurySize`) drawn at
random from whoever is online elsewhere, the first drawn the foreman.
The obligation is one hand — p50 a minute — short enough to ask of a
stranger. The draw is random rather than ranked: uptime or latency
would be levers an attacker could optimise.

### Presence

Every open app that can deal announces itself on the `online` tag every
five seconds (`presence_relay.dart`, `app/lib/net/duty.dart`), with its
activation — whose device it is ([doc 06](06-service.md)) — and serves
as a juror when drawn, without the player noticing. Of two devices of
one account, only the later activation is online. One whose deal
failed to load announces nothing, since it could serve no sealed table.
A device says when it is going — leaving the app or the page — so a
table need not wait out a missed heartbeat.

### The draw

At each hand the lowest key among the participants heard lately proposes
a jury: a snapshot of who is online and the draw, a deterministic
function of the deal's seed, the hand and the snapshot (`drawJury`). The
snapshot holds no device of an account seated at the table, by whichever
of its devices: a player's laptop online while their phone sits at the
table is the player, and as a juror would see a held bot's cards or
judge its own game. The others back the proposal when the draw is what
the snapshot gives, nothing in the snapshot is of an account seated here
as far as their own presence knows, and every juror is somebody they too
have seen in the last five minutes; a majority carries it. A device
summoned to a table its account sits at does not serve it. Presence is
not on the record, so the verifier cannot check whose each juror was;
the backing majority does. The jury is kept beside the record, not in
it. The proposer repeats it every ten seconds until it carries (every
half minute after three tries), and a peer that already backed it
repeats its witness. Nobody inside or outside the table can steer the
draw. The proposer prefers the **settled** — keys announced for at least
a minute (`jurySettledMs`), or seated at a table with a game to finish —
and draws from everyone when too few are; this needs no agreement, since
the table checks only that each juror is somebody it has seen.

A jury stays in force until a later one carries: a table of two with
one gone quiet cannot carry a new one, and that is when it needs the
old. A jury gone quiet is redrawn — topped back up to six, not merely
kept alive — from whoever is left, never including a juror the table
has had to take a seat off.

Everyone at the table summons the jurors. A summons is an event on the
presence tag addressed to one key, carrying the table's spec, the hand,
and the hand's draws with their witnesses, so a juror summoned into a
redraw knows the draw before it. The juror then follows the table like
any peer behind, and the seats dial it.

### Appeals and verdicts

- **The appeal.** A stuck turn — a race that split, or any open turn
  while the table is paused — is appealed every ten seconds. It stands
  while a juror hears it: one unheard for half a minute
  (`appealStandsMs`) is a table the juror has lost, or one that no
  longer asks, and the juror neither carries nor rules on it until it
  hears it again. A juror cut off hears every seat fall silent and
  cannot tell that from its own silence (`juror_cut_off_test.dart`).
- **Carrying.** While an appeal stands, a juror says again, every five
  seconds, everything it holds for the turn: a table cut in two has
  votes on both sides, the juror hears both, and the turn often settles
  without a verdict.
- **The rule.** A juror rules only when nobody who can still vote, as
  far as it can hear, could carry either side. Then by the seat's
  presence to it: heard and acted, the action stands; silent, the
  removal stands. Heard and not yet acted is nobody's to decide; the
  seat's clock runs. The foreman rules first; each juror behind waits
  five seconds more.
- **The verdict** carries the winning event whole, so it settles the
  turn the same way wherever it lands, and travels with the turn when a
  peer behind is carried forward. A removal's verdict travels with every
  carry, so a peer far behind — a juror summoned hands in, reading from
  the first — hears it before the jury that gave it; it keeps the
  verdict for its turn, and asks whose it is there, not on arrival
  (`late_juror_verdict_test.dart`). The verifier checks each verdict
  against the turn, the seat, the event and a jury in force at the
  turn: the hand's own, or the one before up to the turn the hand's
  own carried at — a table of two whose one person left carries the
  hand's draw only once the jury before it has ruled the other out
  (`verdict_before_the_draw_test.dart`).

A rage quit is offline to every juror, so they agree; only a partition
that also splits the jury can give two answers.

## Bot seats the jury holds

A bot seat holds thirteen secret cards. Somebody must open them or the
bot cannot play, and no player may learn them. **The jury plays them.**

At a sealed table with a jury of at least four (`juryToHoldBots`),
`assignBots` gives each bot seat a juror of its own in drawn order,
skipping the foreman, which decides whether somebody has gone and should
hold no seat in the hand it judges. **One juror per seat**: a juror
holding all three bot seats at a table of one person would hold
thirty-nine cards and know the person's thirteen by subtraction.

To the deal, a held seat is an ordinary seat. Its juror draws the seat's
key — a real secret — takes its turns in the deal with every proof, says
its pass and its plays, and publishes the secret at the audit with
everyone else's. Afterwards the verifier checks every card the bot
played against the policy on the hand it turns out to have held. That
is the cost: **a held bot's move is a signed event, checkable after the
hand rather than at the turn.** A juror could play a bot badly for a
colluding player and be caught at the audit rather than live — the same
after-the-fact catch any departed seat already gets.

**The record says which draw a deal is sealed to.** Every seat's keys
name the draw they were sealed to, and the hand's is the one named by
the first person's keys to settle, lowest seat first. A held seat's
juror keys the seat only once that has settled, and from then on a
seat's holder is whoever's keys settled its first deal round — every
side and the verifier read the same holder ([doc 07](07-states.md)). A
jury redrawn mid-hand changes which jurors may act for an escrowed seat
without moving who holds it.

**A table waits for a jury that can hold its bot seats.** Under four
jurors nothing can be held, and at two people and two bots, bot hands
dealt in the open are the other person's hand by subtraction. So a
table with bot seats calls for jurors whenever the pool is short of
four, holds the hand's draw and deal back with no time limit, and says
so ("Waiting for jury…"). The jurors of last resort answer (below).

### Deadlines on a held seat

A bot's move is computed, not thought about, so its holder's clock has
no grace and no bank: **fifteen seconds** for a card or the pass,
**forty** for a deal step or the audit — about three and a half times
the ninety-fifth percentile on a slow machine (two cores shared by four
browsers). The clock starts once the turn is the holder's and nothing is
stalled; for a deal step, once the holder has been heard at the hand,
since a juror just drawn may still be connecting. A device starved of a
processor goes on heartbeating while doing nothing, so a holder is out
when it stops playing, not only when it stops speaking, and is left out
of the next draw. A holder says its seat's part again until it settles,
as a person does: it is the seat's only voice.

### The escrow, and taking a seat over

**A person's deal secret** is split so that any one other person and
any one juror rebuild it ([doc 03](03-fair-deal.md)): one piece to every
other person, one to every juror. When the table removes the seat, the
pieces are released and the seat's hand opens to the table for its bot.

**A held bot seat's secret** goes to the jurors alone, as Shamir shares
over GF(2⁸), any two of which (`escrowThreshold`) rebuild it; no player
holds a piece. A player with one juror's help is exactly who a bot's
hand is hidden from. The pieces are sealed to their custodians while the
hand is played, and go out in the open with the audit.

**When a holder goes, the people take the seat for the escrow, on the
record.** A person whose clocks say the juror is out — unheard for half
a minute, or past its time on the turn — claims the seat for the escrow
at the seat's own turn. The claim is carried as a boot is: by a majority
of the people, or where they split, by the jury, which rules for the
move if the juror is heard and for the escrow if not. For the rest of
the hand the seat is played by the first custodian still heard, the
seat's own juror last. A move the juror said before it knew is as good
as the escrow's (two voices, one card; a split goes to the jury for the
lower id). The escrowed seat's audit closes from the released pieces
(`escrow_on_record_test.dart`, `two_voices_test.dart`).

**The top-up.** A juror drawn mid-hand is given a share of every held
seat by two existing custodians, each sending its part towards the
newcomer's place in the seat's custodian list. The list starts with the
jury the deal was sealed to and grows on the record: a person's play
names the draws that brought somebody in since the last play that did,
and every side adds them in that order (`top_up_test.dart`). A piece
that does not fit its place costs only itself: when the sum does not
open the seat, each pair is tried against the seat's key.

**A juror summoned again is a new client**, which reads the record from
the first hand. A hand before the one it was summoned for is history to
it: it holds no seat there and says nothing about it, and the duty
starts no client for a summons to a hand before where its last client
at that table had got (`juror_summoned_again_test.dart`).

### When quorum is lost

A hand whose held seat nobody left can open, or a turn only the jury can
settle with none of its jurors left, cannot go on.

**In the deal**, before anybody has seen a card, the escrow claimed for
a held seat that still owes a step gives the hand up, unscored and
unaudited, and the next hand is dealt. The verifier asks for that escrow
on the record: a record that walks away from a deal without one is a
hand somebody did not want dealt (`undealt_hand_test.dart`).

**Once the cards are out**, giving the hand up would let a player
holding a bad hand have it dealt again by getting the jurors to leave.
So the game ends instead. A table stopped at such a turn waits, says
so, and goes on if a juror comes back; if not within twenty seconds
(`quorumLostMs`), the people claim the game's end at that turn — one
voice each, as for a boot — and a majority ends the game there on every
record (`TurnState.ended`). Since those who could open the seat have
already been silent half a minute, the game ends no sooner than fifty
seconds after the last of them was heard. The screen says "Connection
failure — juror quorum lost", unscored, and offers the way home. Where
no majority can be had — every voice at the turn already spent, or a
side that hears too little of the table — each side ends the game for
itself.

A side ends the game only while it hears most of the table, or after
everyone it cannot hear has been silent two minutes, so a device that
has lost its own connection does not blame the jury: the rest remove it
for silence. Ending costs the innocent players their game, but lets
nobody choose which hand to keep; the most a losing player gains is an
unrated game, and only if the jurors holding the pieces — strangers
drawn at random — leave together.

### Why the jury size is six

The jury is sized against **f**, the chance a juror drawn at the start
of a hand cannot be reached when its piece is wanted
(`packages/table/tool/jury_size.dart`). With any two enough to open a
held seat, six covers f = 5% to five nines of hands, and four covers 1%.
More jurors cost bandwidth roughly linearly and buy nothing against a
relay outage, which takes every juror at once; what moves f is the draw
preferring the settled and the top-up. `juryToHoldBots` is four: three
would hold, and the fourth is margin for the holder being one that goes.

### Jurors of last resort

A table short of jurors calls for them on the presence tag every ten
seconds, and a **bench** of four jurors we run comes online
(`LastResortBench`, `service/bin/juror.dart`) — four, because a table
needs four before it can hold any bot seat. Each is its own identity,
drawn as anyone is and running the same code. This is the one place a
gameplay event reaches anything of ours, and it says only "a table
needs a juror".

The bench runs as a Cloudflare Container (`service/bench`,
`service/do/bench.mjs`). The relay passes a call to the `Bench` object at
most every twenty seconds, which starts the container if needed and
hands it the call. The bench goes quiet ten minutes after the last call
with nothing to serve and the container is stopped. Anyone can sign a
call; the worst that does is keep one container awake. The bench has no
WebRTC, so it reaches tables over the relay lane.

### What the jury does not change

A juror alone opens nothing. Breaking a hand takes a juror colluding
with a player at that table — drawn at random for it, for the one hand
it matters, with the collusion arranged in advance.

## Watching a live game

A table can be watched from its address (`/table/ID`; `watch.dart`,
`app/lib/net/watching.dart`). Watching is live play, so it is a
subscription's: the watcher's device, its account's device in use, says
on the table's watch lane that it is watching, with its licence, and
one seated player's device answers with what anyone at the table can
see — names, scores, this hand's cards, whose turn, and the keys the
seats are held by, whose [reactions](#reactions) the watcher shows —
after every move while anyone has asked in the last minute. A watcher of an account
seated at the table is not answered: nobody watches their own game from
another device. Nothing hidden is in it. A view is a player's signed
account, believed only as far as a scoreboard is.

## Reactions

A seated player can say one of six things to the table — 👍 Nice,
😂 Ha, 😮 Wow, 😬 Ouch, 🙏 Sorry, 👋 Good game — from the speech bubble
beside their own badge (`packages/table/lib/src/reactions.dart`,
`app/lib/ui/reactions.dart`). There is no free text, so there is
nothing to moderate: on the wire a reaction is a short code and the
moment it was said at, `{"react":"nice","hand":2,"turn":17}`, and each
screen says the word in its own language. It shows beside the sender's
badge for three seconds on every screen at the table and every screen
watching it, and a screen reader says it politely ("Bonnie: Nice").

A reaction is not a table event. It rides the table's tag as an
ephemeral kind of its own (24248), signed by the seat's device, and a
relay forwards it and keeps nothing. It is not in the record, the
results or the game record; nothing the protocol decides — a turn, a
clock, a jury — looks at one; one that is lost is not said again; and a
relay that refuses one is not counted as refusing the table's own
events.

A screen shows one only from a key that holds a seat in person now —
by the table's own state, or for a watcher by the view a player's
device sends it, which names the seats' keys — a code it knows, about
the hand it is at or one either side, made in the last ten seconds,
heard once, and not within two and a half seconds of the last it showed
from that key. A player sends one at most every three seconds. A bot
has no key to say one with, and a table alone has none. Only the
account's device in use is carried by the relay at all, and a device
the account was taken up from has already left its seat.

Anyone can hide everyone else's reactions on their own device, from
under the six or under a game being watched
(`app/lib/reaction_mute.dart`); hidden, none is drawn or said aloud, and
the player's own still shows. On the felt the far seat's goes to the
left of its badge, the right-hand seat's over its badge and the
left-hand seat's under it, each in the strip its badge stands in, so
they run into opposite corners; the player's own takes the button's
place. None is ever over a card, which the large-text suite checks at
every size, language and text size with one at every seat
(`app/test/fits.dart`).

## Game records

When a game is over, each player's device sends its record to be kept
(`game_record.dart`, `app/lib/net/game_records.dart`; the service's
`record` handler, [doc 06](06-service.md)). The first copy is kept, so
the others cost nothing. A record is the table's spec, every decision
with the signed events behind it, the juries that carried, and the
escrow pieces released for seats that left. Each seat in it carries its
licence, so the record says whose each seat was. Whoever opens a game
— a device with a subscription, its account's device in use, and not
one of the game's own players while it is being played — fetches it by
table id and verifies it before showing a card
(`app/lib/review_page.dart`): a copy that verifies is the game, whoever
kept it. Names are kept beside the record unsigned, shown as what each
device said it was called.

## Pictures

A picture comes from a stranger's device. A check on the sender's
device would prove nothing — it belongs to whoever is misusing it — so
any check runs on the **viewer's** device (`app/lib/pictures.dart`). It
fails open: no model, no answer within a few seconds, and the picture
shows, to be taken back if the answer later says so; holding the badge
offers a kept-off picture anyway. No model ships yet; one would be
fetched from the app's origin and checked against a hash the app
carries. Needing no model, holding another player's badge hides their
picture on this device for good.

## Identity

A device's identity is a keypair made on the device when first needed
(`app/lib/identity.dart`): an x-only secp256k1 key with BIP-340 Schnorr
signatures (`signing.dart`; on the web through the wasm in
[measurements](../measurements/README.md)). The key signs every move and
never leaves the device. A person is an **account**, made when they
subscribe ([doc 06](06-service.md)), with up to five devices. The
service's licence names a device's key beside its account's id, and
every peer checks it against the service's key compiled into its build
(`licence.dart`): a seat whose licence is not the service's word for its
key, or an account seated twice, is not a table anyone sits at, serves
or believes. A seat, with its name, rating and result, is the
account's, and so are the pictures a device keeps off and the jury's
exclusions. An account plays on one device at a time:
the newest to take it up wins, and the one before leaves every table,
jury, pool and watch it was at; a seat it leaves is a departure like
any other, a bot in the seat and, at a rated table, a leave. The
service never holds a card, signs a play or adjudicates anything, and a
table under way needs nothing from it.

## How it is tested

- The departure matrix (`packages/table/test/matrix_test.dart`) runs
  leaves, boots and silences on a simulated network on every commit.
- The chaos walk (`chaos_test.dart`, `packages/table/tool/chaos.dart`)
  throws random faults at simulated tables — jurors gone, relays out,
  loss — and checks that no two survivors ever disagree, that every
  record names the same exit for each seat, and that no table is left
  stopped where nobody up could move it. With `--twins` it takes
  jurors' and seated players' accounts up on new devices as it walks,
  and checks that no jury draws a device of a seated account and no
  account is at a table on two devices at once.
- The explorer (`packages/table/tool/explore.dart`) replays a short
  sealed game once per event, peer and change — one copy lost, or
  delivered late — and holds each run to what the table owes.
- The browser suite (`e2e/`) matches strangers with bots and plays a
  friends' room through its departures over real sockets.

## Not addressed

- **Chat.** None. Text between strangers is a moderation surface Hearts
  does not need; the six [reactions](#reactions) are the whole of what
  the players say to each other.
- **Collusion.** Two players sharing hands out of band beat everything
  here. With nothing at stake it is small, which is a reason not to give
  the game stakes.
