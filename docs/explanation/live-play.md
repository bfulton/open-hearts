# Live play

This page explains how the multiplayer game works: getting to a table,
how four devices agree on every turn with nobody in charge, what
happens when people leave, and the jury of strangers that covers what
the players cannot. How the bytes move is in
[multiplayer](multiplayer.md), how the deal stays honest is in
[the fair deal](fair-deal.md), and every state and transition, with the
rules the record holds them to, is in [table states](table-states.md).

Solo play is free and live play is a subscription, so everyone at a
live table holds a licence and sits as an account, on one device at a
time ([the service](service.md), and [identity](#identity) below). The
protocol is `packages/table`, chiefly `client.dart` (with
`deal_driver.dart`, the sealed deal, `juror_role.dart`, this side as a
juror, and `escrow_custody.dart`, the escrow's custodians),
`jury.dart`, `juror_duty.dart`, `matching.dart` and `record.dart` (the
verifier). The app drives it from `app/lib/live/live_controller.dart`
and `app/lib/net/`.

## Getting to a table

There is one screen before a game. The profile behind its top-right
icon holds a name and an avatar: an icon on a colour, or a small
picture (`app/lib/avatar.dart`). It is kept on the device and, for a
subscriber, with the account, so every device of the account shows the
same ([the account's profile](service.md#the-accounts-profile)). A
picture travels once, as a stored event. The live area says which game
is asked for (the target score, and rated or unrated) and, after it,
how many other people are online. The player's own rating is the
number beside their icon, once a rated game has made one.

Nothing goes to a relay without a name, and, the first time on each
device, without the player agreeing to the terms of use: a screen says
that the others will see their name and picture, links the terms, and
asks (`_agreed` in `app/lib/home_page.dart`). The day they agreed is kept
on the device (`Identity.agreedToTerms`). The app stores ask for this
before anyone can publish anything; subscribing is agreeing too, but a
device brought into an account with a code or a sign-in never saw the
subscribe screen.

On a phone, before either of those, the app asks the phone's store
whether the player may play live (`app/lib/net/age_check.dart`, through
the `age_range_signals` plugin), and asks again before the store's
purchase sheet opens, since live play is all it sells. The terms let
anyone play alone and anyone 13 or older play live. Where a law has
the stores keep everyone's age, Texas's among them, the store tells
the app the age range it holds, and the app is to go by it. It asks
for the one line it draws, 13: the App Store's Declared Age Range then
shares only whether the player is under it, and Google Play answers in
its own bands. Live play closes, with a note saying why and that
playing alone is open (`app/lib/age_gate.dart`), when:

- the whole of the store's range is under 13;
- Google Play is waiting for a parent or guardian to approve the app's
  latest significant change, or one declined it;
- Google Play needs the player to confirm their age first, which it
  asks only where a law has it keep everyone's age.

The answer is used for that and nothing else: it is not kept, on the
device or anywhere, and never sent. Where the store has nothing to say
(the web, an iPhone before iOS 26, a phone the store keeps no age for, a
player who chose not to share it, a store that did not answer), the
terms decide, as they always have. Apple gives an app no answer for a
parent's approval withdrawn: the App Store stops the app opening at
all.

### Matchmaking

There is no matchmaker (`packages/table/lib/src/matching.dart`).
Players who want a game say so on the relay at every heartbeat
(`heartbeatMs`), in a pool whose tag names the target score and whether
it is rated. Each says its rating, its pace, how long it has waited and
its licence. Time is cut into rounds (`roundMs`). In each round the
lowest key present acts as host: it runs the seating rule over everyone
it has heard from and publishes one signed start event per table. If
the host says nothing, the next key steps in, so a host can waste a
round but cannot forge a play. A device entering a pool reads the
seatings of the last minute (`poolHistorySeconds`).

The rule:

- Whoever has waited through a round is seated first, then the rest at
  random.
- A table is four ratings within a window that widens by `windowPer`
  points for every round the first of them has waited, and four paces
  within a window that widens by `paceWindowPer` seconds a round.
- Once someone has waited as long as the pool waits before bots
  (`defaultBotsAfterMs`) without a full table, they get one, with bots
  at their own rating in the empty seats.

A player who finds the pool empty may choose to wait for a person
instead, for up to `personAtMostMs`, and then gets bots as everyone
does. Choosing it tells the operator, so that someone can come and play
([the operator's alerts](service.md#the-operators-alerts)).

Two hosts with different views may both seat a round: the next in line
steps in when the host's seating has not reached it in time. A device
takes the lowest table id among the seatings naming it that arrive
within a tenth of a round of the first, and no later one. Usually that
is the same table for everyone. When a seating reaches some devices in
time and others too late, people seated together end up at different
tables. Each person still sits at exactly one table, and a seat nobody
comes to is booted at its first turn and played by a bot. Only
something in charge could rule this out, and nothing is.

A seating names each seat's licence. Nobody sits at one where a seat's
licence is not the service's word for that seat's key, or where an
account sits twice, and a waiter without a licence is not seated by
anyone.

**Pace**, seconds a card, is matched because three fast players and one
slow one make a bad evening for all four. It is a device's own account
of itself (`pace.dart`, `app/lib/pace_store.dart`). The record carries
no clock, so no two peers could agree on how long a seat took, but a
device can time its own turns exactly. Pace decides who you sit with and
nothing else: a player who lies sits with people at a speed they do not
play. A turn longer than the table would ever wait is not counted.

### Friends' rooms

*Play friends* opens a room at a code from `Random.secure()`, drawn from
an alphabet with no lookalikes (`Room.newCode`). The code is all that
keeps a stranger out. Nobody types it: the room offers *Share the link*,
and opening the link lands in the room. On the web the room's address is
in the address bar, so a refresh comes back.

Nobody hosts a room (`app/lib/net/room.dart`). Everyone at a code says
so on the relay at every heartbeat. Whoever has been heard lately is the
table, in arrival order, and the lowest key present leads. The leader
starts the table a short wait after the last arrival (`roomStartMs`,
a [remote config](service.md#remote-config) setting), at once when four
are there, or on *Start now*. A start counts only from someone present
and only if recent, since the relay keeps starts and codes get reused.

The signed start event names everything the seats must agree on: the
seats with their licences, the target score, whether it is rated, and
the table's clocks. Seats that disagreed on any of them would fork. A
room's members say their licences in their beats, and a start whose
seats do not check out is not sat at.

## Bots

**A bot seat says it is a bot**, where a person's name would go. Most
tables at low liquidity are one person and three bots, and the app does
not disguise that with plausible usernames.

**The bots are famous lovers**: Romeo and Juliet, Cyrano and Roxane,
Westley and Buttercup, Orpheus and Eurydice, Casanova, Don Juan and the
rest of `packages/engine/lib/src/persona.dart`. Each is a temperament,
one policy with a few thresholds moved, so Romeo cannot hold a queen
and Don Juan runs at the moon on a hand the others would not. Every
setting is measured to be a choice a strong player might make. A
tournament test seats random fours from the roster and fails if any
persona falls behind, and `packages/engine/tool/blunders.dart` looks for
self-destructive plays in bot-versus-bot games.

**Every character comes at several strengths** (`Persona.levels`, made
by `Persona.at`), so a person is seated with bots near their own rating.
The top rung is the whole policy, and each rung down removes one thing a
player learns, in about the order people learn it. Rung 0 passes its
three highest cards, leads its lowest, follows with its lowest and
throws its highest when void: the rules and nothing else. Then, one rung
at a time:

1. Duck as high as you can.
2. Last to play and taking the trick anyway, throw the top card.
3. Void, throw the queen and hearts first.
4. Pass by shape.
5. Lead small spades to flush the queen.
6. Void, throw a heart before a side card.
7. Throw the top club on the first trick.
8. At the top, run at the moon.

Every rung defends against the moon: a bot that never did would be a
rating pump for anyone who runs at every chance.

The ladder is calibrated in the arena (`packages/table/tool/ladder.dart`,
many thousands of tables of random fours from nearby rungs). Its
ratings are the priors a bot starts from (`Persona.priors`), and from
there a bot floats on its results like anyone. A bot's identity is its
name and rung: `Westley` at the top, `Westley/3` on rung 3. The bot
tools are listed in the [tools reference](../reference/tools.md).

The live view replays the record at a human pace: each bot thinks for
its persona's beat, and a finished trick sits for a moment, so a person
sees every card land (`live_controller.dart`).

## Ratings

**One rule for people and bots** (`rating.dart`, `results.dart`). A
person is an account: whichever of its devices played, the rating is
the account's. A finished rated game is one Glicko rating period with
three opponents, scored pairwise by final total: the lower total wins
the pair, and equal totals halve. A bot that sat down at the deal is
rated like a person, one rating per persona per rung, so any edge a
person finds against the bots is priced in rather than farmed. A bot
that took over a leaver's seat has no stake, and the leaver finishes
last. A rating is shown as provisional while its deviation is wide
(`Rating.provisional`).

**Results are signed and public.** At the end of a rated game every
person at the table publishes the same result, signed with their
device's key, under one tag on the relay (`GameResult.tag`). A result
names the table, the seats, the totals, who was there from the deal and
who left. Each person's line names the account and carries the licence
that says the key it sat with is one of the account's devices, so anyone
folding results can check whose it is. A result stands when a majority
of the accounts that sat down published the same one, each by the device
it sat with. A stranger's word, or the account's other device's, counts
for nothing. At a table of two that majority is both, so each device
waits for the relay to acknowledge its copy, and retries on a fresh
connection a few times while none has (`Standing.publish`).

Anyone can fold every standing result, oldest first, into every rating
(`Ledger`), and the app does so when it reaches the relay. The score
sheet of a rated game shows what the game did ("1500 → 1516") by
folding the device's own result into the ledger it holds. A rating
stated in a pool only decides who you sit with. Every live table is
sealed ([the fair deal](fair-deal.md)), so a rating rests on records
anyone can verify.

## How a table talks

The transport is a WebRTC data channel to every other person and to the
hand's jurors, with the relay as the lane behind it while somebody the
table must reach has no channel open (`MeshTransport`,
[multiplayer](multiplayer.md)). The client says who it must reach as it
learns them (`Transport.reach`: the seats at the start, and the jurors
as each jury carries). The relay list is the build's or the remote
config's. In a deployed build it is one relay, ours, with the tag in the
address so a table meets in one object ([the relay](relay.md)).

A relay must read, check and sometimes store what it carries, so it
gets JSON. A channel has our code at both ends, so it gets the event as
bytes (`frame.dart`): no base64 around the deal's cryptography, no hex
around keys and signatures, and no table id or event id, since both can
be recomputed from the rest. A hand is much smaller that way, with no
compressor (`packages/table/tool/wire_breakdown.dart` measures it). The
canonical bytes underneath are the same, so an event has the same id
whichever way it arrived.

With several relays a client listens on all, and sends room beats,
presence and signalling to all. It writes each table event to the first
relay that everyone it has heard from reads (each heartbeat says which
relays its sender reads). A refused event moves on to the next relay,
and when every relay refuses, the line under the felt says so
(`relays.dart`).

Events that decide something for someone else go by every path: a
boot, a claim of absence, an appeal, a verdict, a leave, a claim for the
escrow. So does a seat's own action the moment a boot or appeal names
it, since a peer that cannot read the relay this device writes to
cannot say so. A device's own events should come back on its
subscription, so a subscription that delivers nothing for a while after
publishing (`RelayConnection.quietMs`) is taken as dead and remade.

## Turns and majorities

Hearts is turn-based, which dissolves most of what would otherwise be a
hard problem. Exactly one seat may act at a time, and the rules, not
who spoke first, say which. The one concurrent question is whether the
seat on turn is still there, and the protocol treats every turn as
exactly that question.

**A turn is a race with two sides.** On one side is the seat's own
action, signed by the seat. On the other is its removal: a boot, pressed
once the seat's clock has run out, or a claim of absence by a peer that
has not heard from the seat for the table's silence (`silenceMs`). Every
other participant backs one side with a signature, never both, and a
side wins with a **strict majority of the participants at that turn**.
Only then does the next turn open, so nothing is ever rolled back.

**Who the majority is of** is a function of the record, not the clock:
the people who sat down, less anyone removed at that turn or earlier. A
peer that has not heard of a removal measures against a larger set,
which can only make it wait.

A peer claims or backs a removal only while it hears from a majority of
the participants. A peer that does not is the one cut off, and says so.
**This is what stops a partition becoming a fork.** Split a table of
four people 2–2 and neither half has a majority, so neither removes
anyone. Both wait, and when the network heals, whoever holds unsettled
evidence repeats it. Split it 2–1 and the two proceed, and the one
learns it is out when the network heals. Where no majority exists (two
people, one silent), the turn goes to the jury.

**A bot seat nobody holds needs no events**: its move is a function of
the deal and the record, which every peer computes. At a sealed table
with a jury, bot seats are held by jurors instead
([below](#bot-seats-the-jury-holds)).

**The record** holds every settled turn and every departure with the
signatures that carried it, in an order every peer reaches on its own:
by hand and position, with departures ahead of the actions at the same
position. Anyone can replay it against the deal (`verifyRecord`,
`record.dart`). Every human action must be signed by its seat's key and
legal, every removal carried by the participants of its moment, and
every majority checked against a set the peer could legitimately have
measured against. Every bot move is recomputed.

### Hearing, repeating and catching up

A peer counts as heard from when it sent something itself, or when its
own signed work first arrives at or past where the hearer stands. A
relayed copy of something already seen is not a sign of life.

Whoever said something that has not settled says it again, at a gap
that widens: two seconds, then four, eight, sixteen, then every half
minute. And at once, on a person's heartbeat, a play or a pass of its
own that the person has not backed: the heartbeat is the person back,
and a card lost to their dropped connection would otherwise wait out
the widening gap, longer than a bot's turn is given
([deadlines on a held seat](#deadlines-on-a-held-seat)). A heartbeat
(`heartbeatMs`) also says where its sender stands, and a peer behind is
sent the turns it is missing, `carryWindow` at a time, unasked. That is
also how it learns of departures it never received. Catching up is
budgeted:

- The lowest key present answers first, and the others only if the
  asker stays behind.
- An event is said again at most once in `carryRepeatMs`, whoever asks.
- All of it is drawn from a budget of `catchUpPerSecond` events a
  second.

A removed seat still sending is carried only to the turn that removed
it.

### A device cut off from the table

A device can stop hearing the table while the table goes on hearing
it: a satellite link on a plane, say, whose way in stalls while its
way out still carries. To the device, everyone has gone quiet; to
everyone else, it is still there. Alone at a table of bots, it hears
most of the table whatever happens, since there is nobody else to
count, so silence alone cannot tell it which side is gone.

Our relay answers everything it is sent, so the device asks its own
line. When it has heard nothing at all for `unansweredMs` (ten
seconds) while something it sent has waited longer than an answer
takes, it takes itself for cut off (`Transport.cutOff`), makes its
socket afresh, and says "Your connection is down — reconnecting"
under the felt. While it is cut off, and for the time it was, nobody
is silent on its word: a juror's half minute, a bot seat's turn, and
a person's silence before a lost quorum are counted from no earlier
than the line's return. So it neither gives a seat up to the escrow
for a move it could not hear, nor ends the game for a jury that was
playing on all along. Once the line is back, the table carries it
forward as it would anyone behind, and a jury really gone is found
out then, a half minute and `quorumLostMs` on.

A table's line opens a moment after the table does, and until it has,
the device is cut off too: it hears nobody yet, so nobody is silent on
its word. But nothing is down, and the screen says so only of a line
that has been up, or of one that has not opened in `unansweredMs`
(`LiveController.lineDown`).

The `botActsMs` and `jurorSilenceMs` clocks are kept above ten seconds
for this ([configuration](../reference/configuration.md#table-clocks)).
A device that loses a game, or whose line is down for two minutes,
tells the operator what it saw
([look into a lost game](../how-to/look-into-a-lost-game.md)).

## Clocks

A person's clock is a bank, not a limit per card (`time_bank.dart`).
Each decision has a grace that costs nothing, and each hand has a bank
that the part of a decision past its grace drains. So a player who
thinks hard over three cards is never bothered, and one who is slow over
every card empties the bank and can be booted. The deal's turns and the
audit, which a device answers by itself, have a fixed clock. Past its
grace a seat's remaining clock shows on its badge, and at empty, a
*Boot* button.

A table's clocks are chosen by the device that starts it, from its
remote config ([the service](service.md#remote-config)), and ride in the
signed start event (`TableTiming`, `timing.dart`). Seats that disagreed
about when a boot was due would back different sides of it. A start
that names none, or one out of bounds, is the standard table everywhere.
Pacing, meaning how often something is said again, is each device's
own. Every clock, with its standard value and bounds, is in the
[configuration reference](../reference/configuration.md#table-clocks).

## Leaving

Strangers leave; it is the medium, not misbehaviour. A person leaving
is replaced by a bot at once, mid-hand: three people should not lose a
game because a fourth got on a train. A seat never comes back to a
person once a bot has it. There are three doors, and all produce the
same fact on the record: **seat N is out as of turn T.**

**Leave**, from the menu. The leave is signed by the leaver at the turn
they stood at, and carried by a majority of the people there. Where a
leave and a boot cross, only one carries
([the leave](table-states.md#the-leave)).

**Boot.** Once a seat's bank is empty and the grace on its current
decision spent, the *Boot* button appears. It is a **trigger, not a
vote**: every peer keeps its own account of each seat's bank and
countersigns once its own clock agrees. A peer holding a signed play
for that turn rebroadcasts it instead, so a boot attempt repairs a
dropped message: a valid play for turn T voids any boot for T. The
player being booted sees their own countdown.

**Silence.** A peer that has heard nothing from a seat for the table's
silence (`silenceMs`) claims its absence the moment its turn is open.
The silence is longer than the bank a stalled seat empties, so an active
table resolves through the visible boot, and a phone that switches apps
for a moment comes back to its seat.

Silence is answered **at the seat's own turn and nowhere else**. A
silent seat still counts toward every majority meanwhile, so someone
else's contested turn can stick for want of its vote, and that turn goes
to the jury. Removing a seat mid-turn would let two peers that apply the
removal at different moments settle the turn opposite ways.

A seat that is booted or falls silent sees *A bot took your seat*.

### Coming back after a reload

A device keeps everything it signed at the table and each hand's deal
secret (`journal.dart`, `app/lib/net/seat_store.dart`), written before
each event goes out. Reloaded, the app goes straight back to the table.
The new client reads its own word back before saying anything, so it
never contradicts a move or vote it already made. It takes its keys from
the kept secret and is carried forward like any peer behind.

A closed connection spends most of the silence allowance at once,
leaving `reloadGraceMs`: enough for a reload, and less than the turn's
own clock, so a device really gone holds the table up no longer than a
slow one. Gone longer, the seat is removed at its next turn, and the
device that comes back is caught up to its own removal
(`packages/table/test/rejoin_test.dart`).

## The jury

Two things cannot be settled by the players alone:

- At **two people**, a silent player leaves the other with one vote of
  two. There is no majority, and from inside, a rage quit and a
  partition look the same.
- Wherever a **seat is a bot** at a sealed table, thirteen secret cards
  need a device to hold and play them that is not a player's.

Both need a party with no stake in the table. So every hand draws a
**jury** of strangers (`jurySize`; [why six](#why-the-jury-size-is-six)),
drawn at random from whoever is online elsewhere, the first drawn the
foreman. The obligation is one hand, short enough to ask of a stranger.
The draw is random rather than ranked: uptime or latency would be levers
an attacker could optimise.

### Presence

Every open app that can deal announces itself on the presence tag at a
steady beat (`presence_relay.dart`, `app/lib/net/duty.dart`), with its
activation, which says whose device it is ([the service](service.md)).
It serves as a juror when drawn, without the player noticing. Of two
devices of one account, only the later activation is online. A device
whose deal failed to load announces nothing, since it could serve no
sealed table. A device says when it is going (leaving the app or the
page), so a table need not wait out a missed heartbeat.

### The draw

At each hand the lowest key among the participants heard lately
proposes a jury: a snapshot of who is online, and the draw, a
deterministic function of the deal's seed, the hand and the snapshot
(`drawJury`). The snapshot holds no device of an account seated at the
table, by whichever of its devices. A player's laptop online while their
phone sits at the table is the player, and as a juror it would see a
held bot's cards or judge its own game.

The others back the proposal when all of these hold:

- The draw is what the snapshot gives.
- Nothing in the snapshot is of an account seated here, as far as their
  own presence knows.
- Every juror is somebody they too have seen online recently.

A majority carries it. A device summoned to a table its account sits at
does not serve it. Presence is not on the record, so the verifier cannot
check whose each juror was; the backing majority does. The jury is kept
beside the record, not in it. The proposer repeats the proposal until it
carries, less often after a few tries, and a peer that already backed it
repeats its witness. Nobody inside or outside the table can steer the
draw.

The proposer prefers the **settled**: keys announced for a while
(`jurySettledMs`), or seated at a table with a game to finish. It draws
from everyone when too few are settled. This needs no agreement, since
the table checks only that each juror is somebody it has seen.

A jury stays in force until a later one carries. A table of two with one
gone quiet cannot carry a new one, and that is when it needs the old. A
jury gone quiet is redrawn from whoever is left, topped back up to full
strength rather than merely kept alive, and never including a juror the
table has had to take a seat off.

Everyone at the table summons the jurors. A summons is an event on the
presence tag addressed to one key. It carries the table's spec, the
hand, and the hand's draws with their witnesses, so a juror summoned
into a redraw knows the draw before it. The juror then follows the table
like any peer behind, and the seats dial it. A juror summoned to a table
again is a new client, which reads the record from the first hand; a
hand before the one it was summoned for is history to it
(`juror_summoned_again_test.dart`).

### Appeals and verdicts

- **The appeal.** A stuck turn (a race that split, or any open turn
  while the table is paused) is appealed again and again. It stands
  while a juror hears it. One unheard for `appealStandsMs` is a table the
  juror has lost, or one that no longer asks, and the juror neither
  carries nor rules on it until it hears it again. A juror cut off hears
  every seat fall silent and cannot tell that from its own silence
  (`juror_cut_off_test.dart`).
- **Carrying.** While an appeal stands, a juror repeats everything it
  holds for the turn. A table cut in two has votes on both sides, the
  juror hears both, and the turn often settles without a verdict.
- **The rule.** A juror rules only when nobody who can still vote, as
  far as it can hear, could carry either side. Then it rules by the
  seat's presence to it: heard and acted, the action stands; silent, the
  removal stands. Heard and not yet acted is nobody's to decide, and the
  seat's clock runs. The foreman rules first, and each juror behind it
  waits a little longer.
- **The verdict** carries the winning event whole, so it settles the
  turn the same way wherever it lands, and travels with the turn when a
  peer behind is carried forward. A removal's verdict travels with every
  carry, so a peer far behind (a juror summoned hands in, reading from
  the first) hears it before the jury that gave it. That peer keeps the
  verdict for its turn, and asks whose it is there, not on arrival
  (`late_juror_verdict_test.dart`).
- **The check.** The verifier checks each verdict against the turn, the
  seat, the event and a jury in force at the turn: the hand's own, or
  the one before it up to the turn the hand's own carried at. A table of
  two whose one person left carries the hand's draw only once the jury
  before it has ruled the other out
  (`verdict_before_the_draw_test.dart`).

A rage quit is offline to every juror, so they agree. Only a partition
that also splits the jury can give two answers.

## Bot seats the jury holds

A bot seat holds thirteen secret cards. Somebody must open them or the
bot cannot play, and no player may learn them. **The jury plays them.**

At a sealed table with a big enough jury (`juryToHoldBots`),
`assignBots` gives each bot seat a juror of its own in drawn order. It
skips the foreman, which decides whether somebody has gone and should
hold no seat in the hand it judges. **One juror per seat**: a juror
holding all three bot seats at a table of one person would hold
thirty-nine cards and know the person's thirteen by subtraction.

To the deal, a held seat is an ordinary seat. Its juror draws the
seat's key (a real secret), takes its turns in the deal with every
proof, says its pass and its plays, and publishes the secret at the
audit with everyone else's ([seats nobody holds](fair-deal.md#seats-nobody-holds)).
Afterwards the verifier checks every card the bot played against the
policy on the hand it turns out to have held. That is the cost: **a
held bot's move is a signed event, checkable after the hand rather than
at the turn.** A juror could play a bot badly for a colluding player and
be caught at the audit rather than live, the same after-the-fact catch
any departed seat already gets. Which jurors hold which seats is fixed
by the draw the hand's deal is sealed to, which the record says
([the draw a deal is sealed to](table-states.md#the-draw-a-deal-is-sealed-to)).

**A table waits for a jury that can hold its bot seats.** With too few
jurors nothing can be held, and at two people and two bots, bot hands
dealt in the open are the other person's hand by subtraction. So a
table with bot seats calls for jurors whenever the pool is short, holds
the hand's draw and deal back with no time limit, and says so
("Waiting for jury…"). The [backup jurors](#backup-jurors) answer.

### Deadlines on a held seat

A bot's move is worked out, not thought about, so its holder's clock
has no grace and no bank: a deadline for a card or the pass
(`botActsMs`) and a longer one for a deal step or the audit
(`botDealsMs`). `timing.dart` says what each was measured against. The
clock starts once the turn is the holder's and nothing is stalled, and
for a deal step, once the holder has been heard at the hand, since a
juror just drawn may still be connecting. A device starved of a
processor goes on heartbeating while doing nothing, so a holder is out
when it stops playing, not only when it stops speaking, and is left out
of the next draw. A holder says its seat's part again until it settles,
as a person does, since it is the seat's only voice.

Left out, unless nobody else can be drawn: a table alone with the
[backup jurors](#backup-jurors) has as many of them as a jury that holds
its bot seats needs, and without the one it let go it could deal no
hand again. So a juror let go is drawn again once, when the table is
short without it. Let go a second time, it stays out, and the table
waits for a jury as any table short of one does.

### Playing ahead

A turn settles on the people's witness, so at a table of one person
and three bots, each bot's card waited for the person's device to have
seen the card before it: three round trips through the person's line
between one of their cards and the next. **A bot seat's juror plays
ahead instead.** A bot's card is the deal's and the cards before it,
worked out the same by whoever works it out, so on hearing the bot card
before its seat's turn, the juror works its own out on a copy of the
hand with that card played and says it at once, for the turn after the
one still open. Every side holds a card for a turn not open yet until
the turn opens, so nothing is decided any sooner; the person's device
just hears the three bot cards together.

A card said ahead names the cards it was worked out on (`after`). Where
the turns before it settle as some other card, which only a juror
saying two cards for its seat can bring about, no side takes it, and
its juror works its card out again on what was played. It plays ahead
on bot seats' cards alone: a person's card can still give way to a
removal.

### When a seat's holder goes

Every seat's deal secret is escrowed: a person's so that any one other
person and any one juror can rebuild it, and a held bot seat's to the
jurors alone, so that no player with one juror's help can
([escrow](fair-deal.md#escrow)). When the table removes a seat, the
pieces are released and the seat's hand opens to the table for its bot.

**When a holder goes, the people take the seat for the escrow, on the
record.** A person whose clocks say the juror is out (unheard for
`jurorSilenceMs`, or past its time on the turn) claims the seat for the
escrow at the seat's own turn. The claim is carried as a boot is, by a
majority of the people, or where they split, by the jury. A person says
the claim that carried again for as long as the turn it was made at
waits on the escrow's card, since a juror that missed it, across a
partition, has nothing to tell it so. For the rest
of the hand the seat is played by its custodians
([the escrow](table-states.md#the-escrow)). A juror drawn mid-hand is
given a piece of every held seat without the secret being rebuilt
([the escrow's custodians](table-states.md#the-escrows-custodians)).

### When quorum is lost

A hand whose held seat nobody left can open, or a turn only the jury
can settle with none of its jurors left, cannot go on.

**In the deal**, before anybody has seen a card, the hand is given up,
unscored and unaudited, and the next hand is dealt
([the abandoned hand](table-states.md#the-abandoned-hand)).

**Once the cards are out**, giving the hand up would let a player
holding a bad hand have it dealt again by getting the jurors to leave.
So the game ends instead. A table stopped at such a turn waits, says
so, and goes on if a juror comes back. If none does within
`quorumLostMs`, the people end the game there, unscored, and the screen
says "Connection failure" over "Juror quorum lost" and offers the way home
([the lost-quorum ending](table-states.md#the-lost-quorum-ending)).

A side ends the game only while it hears most of the table, or after
everyone it cannot hear has been silent for `silenceMs`, so a device
that has lost its own connection does not blame the jury: the rest
remove it for silence. Nor while it is cut off itself
([a device cut off from the table](#a-device-cut-off-from-the-table)). Ending costs the innocent players their game,
but lets nobody choose which hand to keep. The most a losing player
gains is an unrated game, and only if the jurors holding the pieces,
strangers drawn at random, leave together.

### Why the jury size is six

The jury is sized against **f**, the chance that a juror drawn at the
start of a hand cannot be reached when its piece is wanted
(`packages/table/tool/jury_size.dart`). With any two enough to open a
held seat, six covers f = 5% to five nines of hands, and four covers 1%.
More jurors cost bandwidth roughly linearly and buy nothing against a
relay outage, which takes every juror at once. What moves f is the draw
preferring the settled, and the top-up. `juryToHoldBots` is four: three
would hold, and the fourth is margin for the holder being one that goes.

### Backup jurors

A table short of jurors calls for them on the presence tag, and the
**backup jurors** we run come online (`LastResortBench`,
`service/bin/juror.dart`). There are as many as a table needs before it
can hold any bot seat (`juryToHoldBots`). Each is its own identity,
drawn as anyone is and running the same code. Each says it is one
(`RelayPresence.lastResort`), so a device counting who is online to play
with leaves them out. This is the one place a
gameplay event reaches anything of ours, and it says only "a table
needs a juror". For the hands they serve, you trust us not to collude
with a player at your table
([what is guaranteed](fair-deal.md#what-is-guaranteed-and-what-is-not)).
How they run is in
[the relay and the backup jurors](service.md#the-relay-and-the-backup-jurors).

### What the jury does not change

A juror alone opens nothing. Breaking a hand takes a juror colluding
with a player at that table, drawn at random for it, for the one hand
it matters, with the collusion arranged in advance.

## Watching a live game

A table can be watched from its address (`/table/ID`; `watch.dart`,
`app/lib/net/watching.dart`). Watching is live play, so it needs a
subscription. The watcher's device, its account's device in use, says
on the table's tag that it is watching, with its licence. One seated
player's device answers after every move, while anyone has asked lately
(`WatchBroadcast.watchedFor`), with what anyone at the table can see: names,
scores, this hand's cards, whose turn it is, and the keys and accounts
the seats are held by: whose [reactions](#reactions) the watcher shows,
and whom the watcher has [blocked](#blocking-and-reporting). A watcher of
an account seated at the table is not answered: nobody watches their
own game from another device. Nothing hidden is in a view. It is a
player's signed account, believed only as far as a scoreboard is, and
never stored; once the game is over, the review page verifies the full
record ([game records](#game-records)).

## Reactions

A seated player can say one of a fixed few things to the table, such as
👍 Nice or 👋 Good game, from the speech bubble beside their own badge
(`Reaction` in `packages/table/lib/src/reactions.dart`,
`app/lib/ui/reactions.dart`). There is no free text, so there is nothing
to moderate: on the wire a reaction is a short code and the moment it
was said at ([the relay reference](../reference/relay.md)), and each
screen says the word in its own language. It shows beside the sender's
badge for a moment (`ReactionRules.shownFor`) on every screen at the
table and every screen watching it, and a screen reader says it
politely ("Bonnie: Nice").

A reaction is not a table event. It rides the table's tag as an
ephemeral kind of its own, signed by the seat's device, and a relay
forwards it and keeps nothing. It is not in the record, the results or
the game record. Nothing the protocol decides (a turn, a clock, a jury)
looks at one, one that is lost is not said again, and a relay that
refuses one is not counted as refusing the table's own events.

A screen shows one only from a key that holds a seat in person now: by
the table's own state, or for a watcher by the view a player's device
sends it, which names the seats' keys. It must be a code the screen
knows, about the hand it is at or one either side, made lately
(`ReactionRules.staleAfter`), heard once, and not too soon after the
last it showed from that key. A player sends one at most every
`ReactionRules.gap`. A bot has no key to say one with, and a table alone
has none. Only the account's device in use is carried by the relay at
all, and a device the account was taken up from has already left its
seat.

Anyone can hide everyone else's reactions on their own device, from
under the reactions or under a game being watched
(`app/lib/reaction_mute.dart`). Hidden, none is drawn or said aloud, and
the player's own still shows. On the felt the far seat's goes to the
left of its badge, the right-hand seat's over its badge and the
left-hand seat's under it, each in the strip its badge stands in, so
they run into opposite corners. The player's own takes the button's
place. None is ever over a card, which the large-text suite checks at
every size, language and text size with one at every seat
(`app/test/fits.dart`).

## Game records

When a game is over, each player's device sends its record to be kept
(`game_record.dart`, `app/lib/net/game_records.dart`, and the service's
[game records](service.md#game-records)). The first copy is kept, so the
others cost nothing. A record is the table's spec, every decision with
the signed events behind it, the juries that carried, and the escrow
pieces released for seats that left. Behind a removal are its backers'
own signed words, the claims against the seat or that the game ends and
the witnesses of one, so the verifier counts its majority from
signatures, not from the keys the record names. A game kept before
records carried them, in the record's first form, names a removal's
backers by key alone; it still opens, checked by those keys. Each seat
in it carries its licence, so the record says whose each seat was. Whoever opens a game
fetches it by table id and verifies it before showing a card
(`app/lib/review_page.dart`): a copy that verifies is the game, whoever
kept it. That is a device with a subscription, its account's device in
use, and not one of the game's own players while it is being played.
Names are kept beside the record unsigned, shown as what each device
said it was called.

## Pictures

A picture comes from a stranger's device. A check on the sender's
device would prove nothing, since it belongs to whoever is misusing it,
so any check runs on the **viewer's** device (`app/lib/pictures.dart`).
It fails open: with no model, or no answer within a few seconds, the
picture shows, to be taken back if the answer later says so. Holding
the badge offers a kept-off picture anyway. No model ships yet; one
would be fetched from the app's origin and checked against a hash the
app carries. Needing no model, holding another player's badge hides
their picture on this device for good.

## Blocking and reporting

Holding another player's badge at the table also offers to block them,
and to report them.

Blocking is on the viewer's device too (`app/lib/pictures.dart`): the
account is kept on a list there, and wherever this device shows it —
at a table, in a friends' room, watching a game or reviewing one — it
is shown as a blocked player, with no picture, and its reactions are
neither shown nor said. Nobody else is told, and nothing about seating
changes: seating is worked out in the open by the waiting players'
devices ([getting to a table](#getting-to-a-table)), so keeping two
players apart would mean publishing who blocked whom. The list is the
device's own, so another device of the same account keeps its own.

A report goes to the people who run the game, by email, with both
accounts and what the reporter saw (`app/lib/report.dart`;
[reports](service.md#reports)).

## Identity

A device's identity is a keypair made on the device when first needed
(`app/lib/identity.dart`): an x-only secp256k1 key with BIP-340 Schnorr
signatures (`signing.dart`, and on the web the wasm built from
`crypto/schnorr_wasm`). The key signs every move and never leaves the
device. A person is an **account**, made when they subscribe
([the service](service.md)), with a few devices (`mostDevices`, a
[service setting](../reference/configuration.md)). The service's licence
names a device's key beside its account's id, and every peer checks it
against the service's key compiled into its build (`licence.dart`). A
seat whose licence is not the service's word for its key, or an account
seated twice, is not a table anyone sits at, serves or believes.

A seat, with its name, rating and result, is the account's, and so are
the pictures a device keeps off and the jury's exclusions. An account
plays on one device at a time
([one device at a time](service.md#one-device-at-a-time)). The newest
to take it up wins, and the one before leaves every table, jury, pool
and watch it was at. A seat it leaves is a departure like any other: a
bot in the seat and, at a rated table, a leave. The service never holds
a card, signs a play or adjudicates anything, and a table under way
needs nothing from it.

How all of this is tested is in
[testing](testing.md#the-table).

## Not addressed

- **Chat.** None. Text between strangers is a moderation surface Hearts
  does not need, and the [reactions](#reactions) are the whole of what
  the players say to each other.
- **Collusion.** Two players sharing hands out of band beat everything
  here ([what is guaranteed](fair-deal.md#what-is-guaranteed-and-what-is-not)).
  With nothing at stake it is small, which is a reason not to give the
  game stakes.
