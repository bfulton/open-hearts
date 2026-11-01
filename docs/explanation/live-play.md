# Live play

This page explains how the multiplayer game works: getting to a table,
how the table's referee puts everything that happens at it in one order,
how the house holds the bot seats, and what happens when people leave.
How the bytes move is in [multiplayer](multiplayer.md), how the deal
stays honest is in [the fair deal](fair-deal.md), and every state and
transition, with the rules the log holds them to, is in
[table states](table-states.md).

Solo play is free and live play is a subscription, so everyone at a
live table holds a licence and sits as an account, on one device at a
time ([the service](service.md), and [identity](#identity) below). The
protocol is `packages/table`, chiefly `log.dart` (the referee's log),
`rules.dart` (the table as a function of it), `client.dart` (one side at
the table), `house.dart` (the operator's side), `matching.dart` and
`record.dart` (the verifier). The referee is `service/do/referee.mjs`.
The app drives a table from `app/lib/live/live_controller.dart`,
`app/lib/live/lobby.dart` and `app/lib/net/`.

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

The house seats the pools (`PoolHost` in
`packages/table/lib/src/matching.dart`). Players who want a game say so
on the relay at every heartbeat (`heartbeatMs`), in a pool whose tag
names the target score and whether it is rated. Each says its rating,
its pace, how long it has waited and its licence. The pool's object on
the relay wakes the house while anybody waits there and the house is
not there (`service/do/pool.mjs`), as a table's object wakes it for a
table. Time is cut into rounds (`poolRoundMs`). In each round the house
runs the seating rule over everyone it hears and publishes one seating
per table, signed by its key. A device entering a pool reads the
seatings of the last minute (`poolHistorySeconds`).

A seating is the house's alone. A device takes one from its build's
house and nobody else, and the pool's object carries one from nobody
else either: anybody else's is answered as taken, so that the device
that said it is not held out of the relay for it, and goes to nobody.
That one is a stray: an app from before the house seated the pools, or
somebody trying it on.

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

**A table's id is its spec's.** A seating says everything the seats must
agree on: the seats with their licences, the target score, whether it
is rated, the table's clocks, the house and, at a sealed table, the
revision of the deal's messages it is played by
([fair-deal](fair-deal.md#verification)). The table's id is the first
128 bits of the SHA-256 of all of it, as it is written, with 128 bits of
salt from the house so that nobody who saw the seats can work the id out
(`TableSpec.id` in `spec.dart`). The salt is a keyed hash of the rest
under the house's own secret (`seatingSalt`), so the house knows a
table it seated from the table alone ([ratings](#ratings)). The id is
the table's address: the tag its object on the relay is named by. A
device seated works the id out again from the seating, and sits only at
one whose id is its own. The referee takes the log's start only as the
spec its table's id names ([the referee](#the-referee)), so one person
at a table cannot start it as anything but the table everybody was
seated at.

**Each player is seated once.** Whoever a seating names leaves the
pool as it is said. The house hears nothing from them for
`poolStaleMs`, longer than any heartbeat they sent before the seating
reached them takes to arrive, and after that hears them only if they
are still saying they wait, as a device that never took its seating
is. So nobody is named at two tables, and people seated together sit
together. There is one house for every pool and every table
(`max_instances` in `service/do/wrangler.toml`).

Every table a pool seats is sealed and has the house at it, so a pool
needs nothing of the house that its tables did not. With the house
away, nobody is seated, as no sealed table could start without it, and
a device still waiting at its far deadline goes back to the door, saying
so (`relayGiveUp`).

A seating names each seat's licence. Nobody sits at one where a seat's
licence is not the service's word for that seat's key, or where an
account sits twice, and a waiter without a licence is not seated. A
seating names the house that made it (`OH_HOUSE_KEY`), and a device
sits only at one naming its own.

**Pace**, seconds a card, is matched because three fast players and one
slow one make a bad evening for all four. It is a device's own account
of itself, timed from its own turns (`pace.dart`,
`app/lib/pace_store.dart`). Pace decides who you sit with and nothing
else: a player who lies sits with people at a speed they do not play. A
turn longer than the table would ever wait is not counted.

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

The leader's start says the same as a seating: the seats with their
licences, the target score, the table's clocks and the house, with a
salt, under the id their hash makes. A room's members say their licences
in their beats, and a start whose seats do not check out, or whose
table is not its spec's, is not sat at. Each seat at the table is shown
under the name and look its own beats gave, whoever sent the start; the
start's names count only for someone a device never heard.

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

At a live table the bots are the [house](#the-house)'s to play, and a
bot's moment of thought is the house's too: it says each bot card its
persona's moment after the card before (`House.pace`), but never later
than the quickest person at the table would. A person's pace is the
middle of the times they took over their last three cards, by the log's
clock (`tablePaceOf`, `TableRules.cardTimesOf`), so a table never waits
longer on its bots than on its people: someone who plays fast, or turns
on Auto, has the bots keep up within a card or two, without anything
telling the house why. So the log has the bots' rhythm in its own
times, and the screen shows each card as it lands, a beat after the
last, with a finished trick held for a moment, so a person sees every
card land (`live_controller.dart`). A solo table keeps its bots up with
its player the same way, though never quicker than the Auto switch: a
card waits for the one before it to land, and a lead for the trick
before it to be swept (`game_controller.dart`).

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

**Results are the house's word.** Once a game is over, the house says
how it came out in the table's log: the totals, and the log's hash as
it stood when the game ended. It publishes the same result, signed with
its key, under one tag on the relay (`GameResult.tag`), which takes the
house's results and nobody else's. A result names the table, the seats,
the totals, who was there from the deal and who left. Each person's
line names the account and carries the licence that says the key it
sat with is one of the account's devices, so anyone folding results can
check whose it is. A result stands when it is the house's, the house
this build was made with.

Any one of a table's people writes its start, so the house rates only
what it seated. It serves a rated table only when the salt is its own:
a start that says it is rated, naming people whose licences anyone can
read, would otherwise be played out without them and rate them as having
left. A friends' table is never rated, and the house publishes no result
for one where a person seated there never said anything in the log:
whoever started it chose who sat there, and nobody gets a game they
never saw on their record.

Results from before the referee stood when a
majority of the accounts that sat down published the same one; they
are folded as they always were, and no more are taken.

Anyone can fold every standing result, oldest first, into every rating
(`Ledger`), and the app does so when it reaches the relay. The score
sheet of a rated game shows what the game did ("1500 → 1516") by
folding the house's result into the ledger the device holds. A rating
stated in a pool only decides who you sit with. Every live table is
sealed ([the fair deal](fair-deal.md)), so a rating rests on records
anyone can verify.

## The referee

A table's tag on our relay is an object of its own, and the object is
the table's referee (`service/do/referee.mjs`). It keeps the table's log
(`log.dart`): every event a seat or the house sends it, numbered in the
order it came and stamped with the referee's clock; a seat's last
connection to the log closing, and its first opening again; and the
time, when a side asks for it. It sees no cards and decides nothing.

Every side applies the same rules to the same entries in the same order
(`rules.dart`), so every side comes to the same table: who holds each
seat, whose move it is, what was played, who has gone and why, and how
the game ended. Nothing in the rules reads a clock but the referee's, on
each entry; nothing is voted on or guessed. The verifier is the same
rules run over a kept log (`record.dart`), so anybody checking the game
later comes to the same table too.

### What the referee takes

The log begins with the table's start. Each seated person's device
sends one, and the first the referee has is taken: from one of the
table's people, naming this relay's house, and only as Dart wrote it.
Its text must come out the same written again, and its spec must be the
one the table's id names (`startRefusal`). A log that began with a
start the sides could read two ways would be no table at all, for any
of them.

After the start, the referee takes events from the start's people and
its house alone, each once, each signed by its author. Every event's
id, the start's too, must be the hash of the event's canonical bytes
(`events.dart`, made the same way by `eventIdOf` in
`service/functions/records.mjs`), so an id stands for one event and
nobody can keep a seat's move out of the log by saying its id first. An
event the rules do not read, of a kind or shape the build does not
know, is logged as it came and changes nothing, at every side alike
(`LogEntry.unread`).

Each person's events may fill at most `authorMost` characters of the
log, as much as a whole kept game may be (`recordMost`) and some five
times a person's share of a game to a hundred. Past it the referee
refuses that person's events, so their turns run out as a device's
that has gone. The house's events are not held to it.

No event nested deeper than 32 levels is taken (`deepest`); none a build
writes goes past six, a start's licences. Every side walks an event to
the bottom to read it and to write it out again, and one deep enough
would overflow each of them, so the log would go no further for anyone.

A socket is carried at all only once it answers the relay's challenge:
a device in use, by the activation its account's service gave it, or
the house, by its key (`serviceGate` in `service/do/relay.mjs`). The
log is kept a day after its last entry (`KEPT_MS`), for a device coming
back to its table.

### Turns

Hearts is turn-based, which dissolves most of what would otherwise be a
hard problem. Exactly one seat may act at a time, and the rules say
which. Each open turn has an actor, the person in the seat or the house
for a bot seat it holds, and an allowance from the table's
[clocks](#clocks). The first event for it from its actor that checks (a
legal card the seat holds, a pass of three of its cards, a deal step
with its proofs) is taken, and the next turn opens. Anything else stays
in the log and changes nothing.

A turn open past its deadline is lost: a person's gives the seat to a
bot ([leaving](#leaving)), and the house's fails the table
([when the house stops answering](#when-the-house-stops-answering)).
The log puts everything in one order, so there is no race to settle and
no majority to count: a card and a deadline passing are entries, and
whichever came first is what happened.

A deadline passes on the referee's clock, so the referee must be asked
the time. A side that can see a deadline due asks for a tick (`TICK`) a
moment past it, and again every second while nothing has moved the
table. The referee adds one when its last entry is at least a quarter
of a second old (`tickGapMs`), for one of the table's people or its
house, until the house's word on how the game came out is in. It adds
no more than `ticksInARowMost` in a row with no event between them, ten
minutes of them, and none once the log holds `notesMost` ticks and
connections noted, so a table whose house never says that word cannot
be ticked on for ever.

At a sealed table every bot seat is the house's to play. At an unsealed
one, which only the simulator deals, every side works a bot's moves out
for itself.

### Hearing the table

A side hears the table and is heard by it through one line to the
table's object (`referee_line.dart`; `relay_line.dart` over a relay
socket). On every socket the line asks for the log from the first entry
it has not had (`LOG`), takes the entries in order, and when one comes
that is not the next it asks again from there. What it sends is said
again on every new socket until an entry carrying it comes back. There
is no mesh and nobody to catch up from: a side behind reads the log.

The screen is shown the table a change at a time (`TableRules.onFrame`):
a deal, a pass, a card, a trick swept, the next hand, a hand given up,
a seat gone to a bot. The controller shows another seat's card a beat
after the last card (`cardBeat`), holds a full trick for a moment before
it is swept (`Pacing.trickHold`), and gives a hand given up a beat of
bare felt; the player's own card shows at once. A device catching up,
after a reload or a drop, is shown where the table is at once, with no
sheet for a hand it caught up on. The player is asked to pass or play
only once the screen shows the position they are asked about. A bot's
card has its moment in the log already, so the player's turn reaches
the screen a beat, or a trick's hold, after the log opens it.

### A device cut off from the table

A device can stop hearing the table while the table goes on hearing
it: a satellite link on a plane, say, whose way in stalls while its
way out still carries. Our relay answers everything it is sent, so the
device asks its own line. When it has heard nothing at all for
`unansweredMs` (ten seconds) while something it sent has waited longer
than an answer takes (`answerMs`), it takes itself for cut off, makes
its socket afresh (`RelayConnection` in `relays.dart`), and reads on
from the entry it had. A device waiting on others has nothing to
send, so once it has heard nothing for half of `unansweredMs` it asks
for the log again from where it is (`onIdle`): the referee answers
with whatever came since and the log's end, and no answer is what
gives a stall away.

The screen says "Your connection is down — reconnecting" under the felt
once a line that has been up has been down for three seconds
(`downSaidAfterMs`), or a line has not opened in ten: a table's line
opens a moment after the table does, and nothing is down meanwhile. The
table goes on without the device. A person whose connection to the log
stays closed for the table's silence is given up to a bot at their turn
([leaving](#leaving)); one back sooner finds the table where it is. A
table waiting on a person whose line is down says "Waiting for the
others to reconnect", and the person's clock runs on their badge as
anybody's does. A device whose line has been down for two minutes, or
whose game is lost, tells the operator what it saw
([look into a lost game](../how-to/look-into-a-lost-game.md)).

## Clocks

A person's clock is a bank, not a limit per card (`time_bank.dart`).
Each decision has a grace that costs nothing, and each hand has a bank
that the part of a decision past its grace drains. So a player who
thinks hard over three cards is never bothered, and one who is slow over
every card empties the bank. The deal's turns and the audit, which a
device answers by itself, have a fixed clock. Past its grace a seat's
remaining clock shows on its badge, and when it runs out the table
gives the seat to a bot.

The house has a deadline for a bot seat's card or pass (`botActsMs`) and
a longer one for a deal step or its audit (`botDealsMs`), with no grace
and no bank: a bot's move is worked out, not thought about. Past them
it is waited for `houseGraceMs` more, time for a house started again to
come back and read the log, and then the game fails.

A table's clocks are the operator's, from the `table` field of the
remote config row ([the service](service.md#remote-config)): a pool's
table has them from the house, which the relay tells them with every
wake (`clocks` in `service/do/bench.mjs`), and a friends' table from
the remote config of the device that starts it. They ride in the start
in full (`TableTiming` in `timing.dart`, `TableTiming.exactly`):
every side has to time the same table by the same clocks. A start that
leaves a clock out, or names one this build does not know, is no table
it sits at. Every clock, with its standard value and bounds, is in the
[configuration reference](../reference/configuration.md#table-clocks).

## Leaving

Strangers leave; it is the medium, not misbehaviour. A person leaving
is replaced by a bot at once, mid-hand: three people should not lose a
game because a fourth got on a train. A seat never comes back to a
person once a bot has it. Each way out is an entry in the log, or a
deadline the log shows passing, so every side and the verifier have
the same fact: **seat N is out as of entry n.**

**Leave**, from the menu or by going back. While the game is on, the
app asks first, and says what leaving costs: the seat, a rated game
counted as last, and Play live's wait where there would be one
([below](#the-wait-after-leaving-early)). A phone's Back asks the same,
and so does a browser's own Back, which reaches the app as an address
to go to (the route's `onExit`, `app/lib/router.dart`): Stay keeps the
table and puts its address back, and Leave says the seat is given up,
rather than leaving it for the table to find silent. The leave is
signed by the leaver, and the seat is a bot's from the entry it is in.

**Out of time.** A seat whose clock runs out at its turn is given to a
bot at the deadline (booted). Nobody presses anything: the others see
the countdown on the seat's badge, and the player being timed sees
their own.

**Silence.** A person whose connection to the log has been closed, as
the referee noted it, for the table's silence (`silenceMs`, half a
minute) is given up at their turn without waiting on their clock
(absent). Half a minute is time for a reload to come back to its seat.
A device that is there and slow is timed by its clock, and a phone off
the network for longer than the silence comes back to a bot in its seat
if its turn came round meanwhile. Silence is answered at the seat's own
turn and nowhere else, so a seat whose person is away holds nobody up
until it is theirs to move. Once the log holds `notesMost` ticks and
connections noted, the referee notes no more connections closing, so a
person who leaves after that is timed by their clock alone; one it
noted gone before is still noted back when they return.

A seat whose deal shows its person said they held the lead card nowhere
is given up in the hand it broke, and the hand with it
([the one fault no proof catches](fair-deal.md#the-one-fault-no-proof-catches)).

A seat that is given up sees *A bot took your seat*.

### The wait after leaving early

Leaving costs the people still playing a fourth, so a device that
leaves a game Play live seated it at, while somebody else is still
playing it, waits before Play live seats it again: five minutes, or the
remote config's `leftEarlyMin`
([configuration](../reference/configuration.md#remote-config)). Playing
alone and friends' rooms never wait, and leaving a friends' room starts
no wait: friends settle that among themselves.

What counts (`LiveController.leftEarly`):

- Leaving by the menu or by Back while the game is on, with another
  person still seated.
- A seat the table gives to a bot, its clock run out or its connection
  gone quiet, with another person still seated and the game not over.
- A seat kept to come back to and found too old to come back to
  (`SeatStore.load`, `gone`): the app closed mid-game for longer than a
  table waits. The wait counts from when the device was last at the
  table.

What does not: a game that failed for everyone, a device that could no
longer run the deal, and an account taken up on another device
(`net/in_use.dart`), which is the player using it there.

The wait is the device's alone (`app/lib/live/left_early.dart`). It
keeps the time of its last early leave until the wait after it is over;
meanwhile Play live is shut and says until when, and `Lobby.play`
refuses. A time kept ahead of the device's clock, which was set back
since, counts from now instead, so the wait never runs longer than it
says. Nothing else holds a device to it: matchmaking has nobody in
charge to ask. A device whose storage was cleared, or a build changed
to skip the wait, plays again at once. Like pace, it decides nothing
anybody else has to trust.

### Coming back after a reload

A device keeps each hand's deal secret as it draws it (`journal.dart`,
`app/lib/net/seat_store.dart`). Reloaded, the app goes straight back to
the table, reads the log from its start, and takes its keys from the
kept secret. Everything it said is in the log, so there is nothing else
of its own to remember and nothing it could contradict. A step it made
before the reload that reaches the log after the new run made its own
is the one taken, and the hand's deal is built again from the log
without the new one (`rules.dart`).

While its connection is closed, the seat has the table's silence to
come back in, which is enough for a reload. Gone longer, the seat is
given to a bot at its next turn, and the device that comes back reads
the log to its own removal and is told so.

## The house

The house is the operator's side of every live table (`house.dart`;
`service/bin/house.dart`). It follows each table it is called to from
the log's start, and:

- holds every bot seat that is a bot when a hand begins, and plays it:
  its keys, its shuffle and its tokens with every proof, its pass and
  its cards ([seats nobody holds](fair-deal.md#seats-nobody-holds));
- holds one half of every person's escrow, and says it when that person
  goes ([escrow](fair-deal.md#escrow));
- says how the game came out once it is over: the totals, and the log's
  hash as it stood then, which is what a kept game and a rating are
  checked against.

One key does all of it. The house's key is compiled into every build
(`OH_HOUSE_KEY`), and a sealed table names it in its start. A bot's
move is its policy's on the hand the deal gave it, so the house's cards
are checked after the hand, when the audit opens the bot seat's secret:
the verifier works out every bot card again and holds the house to it.
The house thinks over each card for its persona's moment before it
says it (`House.pace`; [bots](#bots)).

The house runs as one process for every table, in a Cloudflare
Container the relay's Worker owns (`service/do/bench.mjs`). A table's
object wakes it as the table starts, and again whenever the house is not
on the log, at most once in twenty seconds (`wakeEveryMs`), until the
house has said a result there. The
container is stopped once the house has had nothing to serve for ten
minutes. Every bot seat's deal secret is made from the house's own
secret, so a house started again reads the log from the start and goes
on where it was.

### A person's hand when they go

When the table gives a person's seat to a bot mid-hand, the person's
hand is opened from the escrow: the house says its half, and any other
person at the table says theirs, since each of them holds the same
other half. Every clock stops meanwhile, and the screen says "Opening a
departed player's hand". From then on, for the rest of the hand, every
side works the seat's cards out as its bot plays them; from the next
hand the house holds the seat. A hand that is not opened within the
fixed clock (`fixedMs`: the house's half or the other people's never
came) is given up and dealt again
([the abandoned hand](table-states.md#the-abandoned-hand)).

A person alone with the house has nobody else to hold the other half,
so their hand can be opened by nobody. If they go, the game ends with
them.

### When the house stops answering

Nobody but the house can play a bot seat's cards. A turn of the house's
that runs out, its deadline and `houseGraceMs` after it, fails the game:
it ends there, and nobody is rated on it. The screen says "Connection
failure" over "The game's server stopped answering", and offers the way
home, and the device tells the operator once.

### When the house will not serve a table

Any one of a table's people writes its start, so the house reads the
start once and checks it against what does not change: the service's
key and its own secret. It will not serve a table with a seat that has
no licence the service signed for its key, held to the day the table
began and not the day it is read, or with one account seated twice; and
not a rated table whose salt is not its own
([ratings](#ratings)). It says so once, in the table's log: a result of
its saying `failed`, which names the log as it stood after its start
(`TableRules.refusal`), whatever came into the log before the word.
Every side ends the table there, failed, as when a turn of the house's
runs out, but at once, and nobody is rated on it.

The word is also what stops the table asking for the house. The
referee asks for it, at most once in twenty seconds, until the house
has said a result; a house that merely let such a table go was woken
for it every twenty seconds until the log's notes ran out, some eleven
days, and a subscriber who started many such tables could multiply
that. The word goes in the table's own log and nowhere else: the house
publishes nothing on the results tag for a table it will not serve, and
reads nothing more of it once it has said the word.

A table the house has not yet reached, or reached through a relay that
was down, is not refused: the house says the word only of a table whose
start it has read and checked, and what it checks never changes.

### What the house can see

The house alone opens nobody's hand: it holds half of each person's
escrow, and the other half is the other people's, said only once that
person has gone. It does know the bot seats' cards, which it plays. At
a table of one person and three bots, those are every card but the
person's, so the house can work out the person's hand by subtraction,
as the person can work out the bots'. At any other table it cannot,
without a person at the table showing it theirs. The operator runs the
house, and the [privacy policy](https://openhearts.game/privacy) says what
it does with what it sees. Whatever it does, the game is checked after
the fact: every bot card against the policy, and every card against the
deal ([what is guaranteed](fair-deal.md#what-is-guaranteed-and-what-is-not)).

## Watching a live game

A table can be watched from its address (`/table/ID`; `watch.dart`,
`app/lib/net/watching.dart`). Watching is live play, so it needs a
subscription. The watcher's device, its account's device in use, says
on the table's tag that it is watching, with its licence. One seated
player's device answers after every move, while anyone has asked lately
(`WatchBroadcast.watchedFor`): of the seats still held in person, the
lowest key whose line to the referee is open (`WatchBroadcast.answers`).
It answers with what anyone at the table can see: names, scores, this
hand's cards, whose turn it is, and the keys and accounts the seats are
held by: whose [reactions](#reactions) the watcher shows, and whom the
watcher has [blocked](#blocking-and-reporting). A watcher of an account
seated at the table is not answered: nobody watches their own game from
another device. Nothing hidden is in a view. It is a player's signed
account, believed only as far as a scoreboard is, and never stored;
once the game is over, the review page verifies the full record
([game records](#game-records)).

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
ephemeral kind of its own, signed by the seat's device, and the relay
forwards it and keeps nothing. It is not in the log, the results or the
game record. Nothing the table decides (a turn, a clock) looks at one,
and one that is lost is not said again.

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
(`record.dart`, `app/lib/net/game_records.dart`, and the service's
[game records](service.md#game-records)). The copy kept is the one that
carries the house's result, so a copy cut short does not stand in the
way of the game. A record is the table's spec and the referee's
log, every entry as it came, the house's word on the end among them.
Each seat in the spec carries its licence, so the record says whose
each seat was.

Whoever opens a game fetches it by table id and verifies it before
showing a card (`app/lib/review_page.dart`): every signature, every move
against the rules and the cards its seat held, every step of the deal,
and the house's result, which names the log by its hash. A copy with
any entry changed, dropped, added or put out of order is not the log
the house signed for, and does not verify. A copy that verifies is the
game, whoever kept it. Opening one is live play: a device with a
subscription, its account's device in use, and not one of the game's
own players while it is being played. Names are kept beside the record
unsigned, each put there by its own seat's device, and shown as that
device said it was called; a seat whose device has not sent shows as a
seat with no name does.

A game kept before the referee, in the record's earlier forms, still
opens, checked as it was then (`legacy/v2_record.dart`).

## Pictures

A picture comes from a stranger's device. A check on the sender's
device would prove nothing, since it belongs to whoever is misusing it,
so the service checks a picture once, when the account sets it, before
any player is shown it ([the account's
profile](service.md#the-accounts-profile)), and the relay carries only
an account's checked picture ([an account's
pictures](relay.md#an-accounts-pictures)). On the viewer's device,
holding another player's badge hides their picture there for good,
until it is shown again (`app/lib/pictures.dart`).

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
device.

That includes the phone's backups. A phone backs up an app's
preferences, to its owner's Google or iCloud account and to the next
phone, so on a phone the key is not kept among them
(`app/lib/secret_store.dart`):

- **Android** keeps it in a preferences file of its own, `identity.xml`.
  `res/xml/data_extraction_rules.xml` (Android 12 and later: Google's
  backup, and a transfer to a new phone) and `res/xml/backup_rules.xml`
  (11 and earlier) leave that file out, and nothing else.
- **The iPhone** keeps it in a file in Application Support marked as not
  to be backed up (`IosSecretStore`, with two calls in
  `app/ios/Runner/AppDelegate.swift`). The file is written only after it
  is marked, and the app refuses a key its file does not say is marked.
- Both go with the app when it is deleted, as the preferences did, so
  deleting the app still removes the key. The Keychain is not used: its
  items outlive the app.
- The web keeps the key in the browser's storage, as before
  ([the device, carried over](service.md#the-device-carried-over)).

A phone restored from a backup, or moved to a new phone, comes back
without its key, as a new player, and gets its account back with a
backup code, a sign-in or Restore purchases. The rest of what the
backup holds, the settings among it, comes back.

A device that kept its key among the preferences before moves it at its
first start (`Identity.signer`): the key is written to the store, read
back, and taken out of the preferences only when the store gives back
exactly what was written. A move that fails leaves the key where it was,
still the device's key, and is tried again at the next start; no key is
made while either place holds one, and a store that cannot be read is
not taken for an empty one. A backup made before the move still carries
the old copy, and a phone restored from it moves that key into its store
at its first start. Starting afresh deletes the key from the store as
well as clearing the preferences (`app/lib/start_afresh.dart`).

A person is an **account**, made when they subscribe
([the service](service.md)), with a few devices (`mostDevices`, a
[service setting](../reference/configuration.md)). The service's licence
names a device's key beside its account's id, and every side checks it
against the service's key compiled into its build (`licence.dart`). A
seat whose licence is not the service's word for its key, or an account
seated twice, is not a table anyone sits at, serves or believes.

A seat, with its name, rating and result, is the account's, and so are
the pictures a device keeps off. An account plays on one device at a
time ([one device at a time](service.md#one-device-at-a-time)). The
newest to take it up wins, and the one before leaves every table, pool
and watch it was at: the relay turns its sockets away, and a seat it
leaves is a departure like any other, a bot in the seat and, at a rated
table, a leave. The service holds no person's card and signs no
person's move. The house, the operator's other side, holds the bots'
cards and half of every escrow, and a table under way needs it
([the house](#the-house)).

How all of this is tested is in
[testing](testing.md#the-table).

## Not addressed

- **Chat.** None yet. Text between strangers is a moderation surface
  Hearts does not need, and the [reactions](#reactions) are the whole of
  what the players say to each other. Voice and video among friends are
  planned (`ROADMAP.md`), over WebRTC through TURN and nowhere else, off
  the game's path ([multiplayer](multiplayer.md)).
- **Collusion.** Two players sharing hands out of band beat everything
  here ([what is guaranteed](fair-deal.md#what-is-guaranteed-and-what-is-not)).
  With nothing at stake it is small, which is a reason not to give the
  game stakes.
