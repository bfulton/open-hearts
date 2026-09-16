# 04 — Live play

The design of the multiplayer game. How the deal stays honest is
[doc 03](03-fair-deal.md); how the bytes move is
[doc 02](02-multiplayer.md).

Solo play against bots is free on every platform. Live play requires a
purchase, and everyone at a live table has made it — there is no guest
seat and no free tier to design around.

## The shape of it

You open the app, tap **Play**, and you are in a game. Not a lobby, not a
list of rooms, not an invite to send. Seconds, not minutes.

That is the whole product decision and everything below follows from it.
Hearts is played in the gaps of a day, and anything that puts a waiting
room between the intent and the cards loses to the app that doesn't.

Matchmaking waits about ten seconds for other people. When the window
closes, bots take whatever seats are still empty and the deal runs. Four
seats, always.

## The empty room

At the start almost every table will be one human and three bots, because
that is what low liquidity looks like. The usual fix is to hide it — give
the bots plausible usernames and let people assume.

**We don't, ever.** A bot seat says it is a bot, where a person's name
would go. This is not a scruple, it is the product: what distinguishes
this app is that it does not lie to you about what is happening at the
table, and an app that fakes its opponents has already conceded the
argument it exists to win.

Tables keep filling. Arriving players take bot seats at hand boundaries,
so a table that starts at one human and three bots may be three and one
by the fourth hand. The state is always on screen — how many seats are
bots, and a note when somebody sits down.

**The bots have names, and the names are famous lovers.** Romeo and
Juliet, Cyrano and Roxane, Westley and Buttercup, Paolo and Francesca,
Lancelot and Guinevere, Aragorn and Arwen, Orpheus and Eurydice, Mark
Antony and Cleopatra, Shah Jahan and Mumtaz Mahal, Marie and Pierre
Curie, Bonnie and Clyde, Diego Rivera and Frida Kahlo, Sid and Nancy,
Han and Leia, Heathcliff and Catherine, Darcy and Elizabeth, Cupid and
Psyche, Dimitri and Grushenka, Pip and Estella, Casanova, Don Juan —
open hearts. Each is a temperament: the one policy with a few of its
thresholds moved, so Romeo cannot hold a queen and Juliet waits for the
moment and Cyrano lets a run go a long way before spoiling it and Don
Juan runs at the moon on a hand the others would not. Every setting is
a choice a strong player might make, and that is measured, not
assumed: a tool plays each setting alone against the baseline, and a
tournament test seats random fours from the roster and fails if any
persona falls behind — a character may be rash or patient, never bad.
The measuring keeps moving things from style to rule: emptying a short
suit in the pass is worth a third of tables instead of a quarter, and
never shooting the moon costs six points of tables, so every bot voids
and every bot shoots when the hand is plainly a shot. A tool that
looks for self-destructive plays in bot-versus-bot games
(`packages/engine/tool/blunders.dart`) found more, each worth two or
three points of tables, and every bot now plays them: throw the
highest club on the first trick, where no point can fall; do not take
points to break up a "run" that is exactly thirteen — somebody caught
with the queen, not somebody collecting; and void in the led suit,
throw a heart, any heart, before a side-suit card. The lead went the
same way: the lowest card in the hand, whatever its suit, measured two
points of tables better than the lowest card of the shortest suit and
three and a half better than the long suit Cyrano used to lead from,
so everyone leads it now, and the rule against leading a high spade
into the queen has nothing left to do. Two habits went the other way,
out — keeping the top heart back as a stopper for a moon, and a
choice of suit to lead from — because they measured worse at every
table where the others do what every bot does. The roster is data in
`packages/engine/lib/src/persona.dart`; the oblivious circuit takes
the same settings as constants, so a named bot holding a departed seat
is the same computable consequence as any other.

**Every character comes at nine strengths.** A person is seated with
bots near their own rating, so each persona is also a ladder
(`Persona.at`): the top is the whole policy, and each rung down takes
away one thing a player learns, in about the order people learn it. A
first game — rung 0 — passes its three highest cards, leads its
lowest, follows with its lowest and throws its highest card when void:
the rules, and nothing else. Then, one rung at a time: duck as high as
you can instead of as low; last to play and taking the trick anyway,
throw the top card; void, throw the queen and the hearts before
anything else; pass by the shape of the hand, not just by height; lead
small spades to flush the queen; void, throw a heart before a side
card; throw the top club on the first trick; and at the top, run at
the moon. One thing every rung does is break up someone else's run. A
table that never does is a rating pump for anyone who runs at every
chance — 44% of tables against three that never defend — and a bot
that could be farmed that way would poison every rating it touched;
so defending the moon is not a rung, it is the floor. The ladder is
calibrated in the arena (`packages/table/tool/ladder.dart`): twenty
thousand tables of random fours from nearby rungs, fitted by the same
model a rating's expected score uses, to two or three points a rung.
It spans about 240 points — a first game finishes ahead of the whole
policy in one pair of three — with rungs thirteen to forty-two points
apart and the forty characters at a rung within about twenty-five
points of each other. Those are the ratings a bot starts from; from there it
floats on its results like anyone, one rating per character per rung.
A bot's identity is its name and its rung: `Westley` at the top,
`Westley/3` on the third rung up from a first game.

## The live table, as it stands

What the app does today. There is one screen before a game, and
everything that comes before one is on it. Who you are is the icon in
its top right and the profile behind that icon: your name, and your
avatar — one of a set of icons on a colour, or a picture of your own,
sixty-four pixels square, both kept on the device and carried to the
others together: the name, icon and colour in every beat, the picture
once, as a stored event (what is done about a picture nobody asked
for is below). A game that needs a name and finds none opens the
profile for one. Then *Play solo*, and under it the live area, which
carries the game being asked for on a line of its own: fifty points
or a hundred, rated or unrated, changed in a small sheet and kept on
the device beside the name. *Play live* is one button — the options
say which pool — and it carries how many devices are online, since
that is the reason to press it now or to come back later. Pressing it
is a waiting screen and nothing to do. (Live play is a subscription
now — `liveOpen` in `app/lib/home_page.dart` asks whether this device
holds a licence; see [doc 06](06-service.md).) There is no
matchmaker.
Players who want a game say so on the relay every couple of seconds,
in the pool they chose, with their rating, their pace and how long
they have waited; everyone waiting sees everyone else. Time is cut into rounds
of five seconds, and in each round the lowest key present acts as
host: it runs the seating rule (`packages/table/lib/src/matching.dart`)
over everyone it has heard from and publishes one signed event per
table naming the seats, the same start event a friends' room uses.
The rule: whoever has waited through a round already is seated first,
then the rest at random; a table is four ratings within a window that
widens a hundred points for every round the first of them has waited,
and four paces within a window that widens three seconds a round; and
once someone has waited ten seconds without a full table they get
one, with bots at their rating — the ladder above has every character
at every strength — in the seats nobody came for. A pace is how long somebody takes over a card, and it is
there for a plain reason: three people playing a card a second with a
fourth who reads the whole hand each turn is a bad evening for all
four, whatever anybody is rated. It is the looser of the two windows,
since a rating decides whether the game is any good and a pace only
decides whether the evening is.

A pace is also the one number about a game that **no two peers can
agree on**, and that is worth being explicit about. Everything else a
table settles is derived from the record, and the record carries no
clock at all: an event is `(table, author, kind, body)` and nothing in
it says when. The time bank works because each peer measures for
itself and a majority has to agree, not because the number is shared
— `bankLeftMs` is "by this peer's clock" and says so. Four peers asked
how long a seat took would sign four different numbers, and a result
needs a majority of identical ones to stand, so a pace can never go
in one.

What a device *can* measure without dispute is its own turns: the
clock it started when the turn opened and stopped when it played. So
a pace is a device's own account of itself, kept on the device
(`app/lib/pace_store.dart`), stated in the pool exactly as a rating is
stated there — and it decides who you sit with and nothing else.
Nobody is ever told how long anybody took. A player who lies about it
is seated with people who play at a speed they do not, which is its
own punishment and costs nobody else a game. A turn longer than the
table would ever wait — a card's grace plus the whole bank — was
somebody who walked away rather than somebody thinking, and is
dropped rather than counted.

If the
host says nothing for a round, the next key steps in — a host can only
waste five seconds, and it cannot forge a play. Two hosts with
different views may seat someone twice; they take the seating with the
lower table id, and the other table's empty seat is booted at its first
turn. A rated table says so on the felt and in its record, and every
name on it carries a rating. The score the game runs to travels the
same way: it is in the signed start event, since four seats that
disagree about when the game ends fork at the end of a hand, and it
is part of the pool's tag on the relay, so everyone who meets in a
pool wants the same game. Beside *Play live*, *Play friends* starts a
table of its own at a code drawn at random — eight characters from
`Random.secure()`, out of an alphabet with no lookalikes in it, since
the code is the whole of what keeps a stranger out of a private table.
Nobody types a code, and no screen shows one: the room offers *Share
the link*, the link carries the code, and opening it lands in the
room. On the web the room's own link is in the address bar while the
device is in it, so a refresh comes back and the address is there to
copy.
Nobody hosts a room: everyone at a code says so on the relay every two
seconds, whoever has been heard lately is the table in the order they
arrived, and the lowest key present leads — it starts the table ten
seconds after the last arrival, at once at four, or on *Start now*, by
the same kind of start event, and a leader who leaves is simply no
longer present (`Room`). A start counts only from someone present and
only if recent, since the relay keeps them and a code gets reused. The transport is a WebRTC data channel to every
other person, set up over the relays' signalling and carrying the
table's events directly, and through a relay as well — the path to a
peer whose channel is not open, and the only path to a juror, which
follows from the relays alone (`MeshTransport`). Relays, plural: a
client holds a short list — the build's, not a setting anyone types
(`app/lib/net/relays.dart`) — keeps a subscription on every one of
them and writes each table event to the first that has not refused it
lately, our own relay ahead of the volunteer ones while it is up
(`relays.dart`, `app/lib/net/relays.dart`); what forms a room and what
sets up a channel — a lobby's beats and starts, presence, signalling —
goes to every relay, since a device that has lost one relay must still
be seen and reached on the others, or two tables start under one code.
Which one relay a table event goes to is chosen for its readers: every
heartbeat says which relays its sender is reading, and a writer takes
the first relay in its order that everyone heard from lately reads —
every relay that is up, when there is no such one — so a device that
has lost a relay, or never had it, is written to where it can hear.
And what goes unanswered goes the same way: an action still
unwitnessed after four seconds, and every ten after, a boot, a claim
of absence, an appeal, a verdict, a leave, every sixth heartbeat,
whatever a juror carries, and — the moment a boot or an appeal names
this seat — its own action for the turn, or a heartbeat if it has
none. A reader that cannot read the relay this device writes to cannot
say so, and is exactly the one that must hear it: a table that took a
seat's silence for absence when the silence was its own deafness is
the failure this prevents. A public relay is volunteer infrastructure
with rate limits and no uptime promise, and one turned on a live table
six minutes in — every event answered with a proof-of-work demand, the
play on its way reaching nobody, the seat booted for silence — so a
refusal moves the event on to the next relay, and when every relay
refuses, the line under the felt says so. Writing to one keeps the
relays' cost what it was; listening on all is what lets peers that
write to different ones hear each other. The list's order is turned by
a hash of the table id, so tables spread over the relays. The table is
drawn from whichever chair you hold. On the felt, who has been heard
from lately; on the line under it, the boot clock on a seat that is
holding everyone up, and the *Boot* button when it runs out, and, when
the table is
stuck, why —
no relay taking this device's events, waiting for the others, asking
the jury, waiting for a jury when nobody was
online to draw one from, or opening a departed player's hand from its
escrow. *Leave the table* is on the menu. A seat that is booted or
falls silent sees *A bot took your
seat*. Every table is sealed ([doc 03](03-fair-deal.md), "As built"):
the line shows the deal at each hand — the keys, the shuffling, the
cards dealt and opened — for a couple of seconds on a desktop and a few
on a phone, and the other people's cards are backs that nobody but
their holder can turn. Every open app says it is online and serves
as a juror when drawn (`app/lib/net/duty.dart`), at another table or
at the front door, without the player noticing. The device's key is
minted the first time it is needed and kept; on the web every
signature goes through the wasm
([measurements/sign](../measurements/README.md)). A widget test seats
the player at seat 2 with three simulated people and plays a hand,
watches one leave and boots one for silence; the browser suite
(`e2e/`) matches three strangers with a bot and a fourth with three,
then plays the friends' room through its departures.

### A picture nobody asked for

A picture arrives from a stranger's device, so the question is what to
do about one most people would not want at a table. The answer is not a
check on the sender's device signing that it behaved: that device
belongs to whoever is misusing it, the signing key would ship inside
the app, and the web has no root of trust that could say otherwise. A
signed self-check stops carelessness and looks like a defence, which is
the dangerous kind of feature.

So the check runs on the device doing the looking
(`app/lib/pictures.dart`), where it needs nobody's permission to be
believed: the viewer ran it themselves. It fails open — no model at
hand, a model that will not load, bytes it cannot read, an answer that
does not come inside a few seconds: the picture shows. A check that is
right most of the time is worth having; one that hides faces whenever
it is unsure is not.

A picture waits on the check only where waiting is free. A check with
its model loaded answers in a few milliseconds, so the picture is held
for that and appears once, correctly. Everything else shows and is
taken back if the answer says so: a model still coming down the wire, an
answer that is taking its time, or bytes already on the table when the
model lands. Being seen for a moment and withdrawn is what failing open
costs, and it is cheaper than a table of blank badges every time the
check is slow — and it is the only thing that works at all for the
pictures already on screen when the model arrives mid-game. A picture
kept off is kept off the badge rather than blurred, and holding the
badge offers it anyway, with the note that the guess was made here and
can be wrong.

Under that is the part that needs no model at all: holding another
player's badge hides their picture on this device, for good, and their
name and their score stay. It is the viewer's own decision, kept with
their identity, and it is the backstop the check fails open onto.

The model itself is not shipped yet. When it is, it is fetched at
runtime from the app's own origin rather than bundled — so it costs
nothing on first load, and is cached after the first picture that needs
it — and the app checks it against a hash it carries, so a compromised
host cannot swap the model for one that likes everything.

## Ratings

**One rule for people and bots, from the same results.** A finished
rated game is one rating period with three opponents, scored pairwise
by final total — the lower total wins the pair, equal totals halve —
and folded by Glicko: a rating and a deviation, the deviation saying
how much the rating is worth (`packages/table/lib/src/rating.dart`). A
bot that sat down at the deal is rated exactly like a person, one
rating per persona per rung of its ladder, starting from the rung's
calibrated prior, from every table it ever sat at; that is what makes
a table of one person and three bots worth playing, and worth the
same as any other — the bots' ratings float on real results, so any
edge a person finds against them is priced in within a few hundred
games rather than farmed. A bot that took over a leaver's seat has no
stake in the result. A leaver finishes last, whatever their seat scored
after they went.

**Results are signed and public.** At the end of a rated game every
human at the table publishes the same result — the table, the seats,
the totals, who was there from the deal and who left — signed with
their key, on the relay under one tag (`results.dart`). A table's
result stands when a majority of the humans who sat down published the
same one; a stranger's word counts for nothing. Anyone can fold every
standing result, oldest first, into every rating; the app does so when
it reaches the relays, shows the player theirs in the live area of the
front door, and states it when waiting to be seated. At the end of a
rated game the score sheet says what the game did to it — "1500 → 1516"
— which the device works out for itself by folding the result it has
just published into the ledger it already holds, rather than waiting to
hear its own result back off a relay; where that new rating is not
known, the sheet says nothing about ratings at all. Lying there only
changes who you sit with.

**Backed by the deal.** Every live table is sealed ([doc
03](03-fair-deal.md), "As built"): its cards come from a deal nobody
at it could rig, and its record replays through that deal, every
proof checked, so a rating is a claim anyone can verify. One interim
remains, and doc 03 names it: a bot's hand, and a departed person's,
is open to the table until the bot plays inside the computation
(below). It says "provisionally" until a rating has settled.

## Filling and emptying seats

**A human joining takes a bot's seat at the next hand boundary, never
mid-hand.** Mid-hand they would inherit a position shaped by decisions
they did not make and — worse — inherit knowledge of thirteen cards from
whoever was holding that seat.

**A human leaving is replaced by a bot immediately, mid-hand.** The
opposite rule for the opposite reason: three people should not lose a
game because a fourth got on a train.

## Leaving, through three doors

Strangers leave. That is not misbehaviour, it is the medium, and the
design assumes it rather than penalising it.

**Explicit.** A Leave button, and the event is signed by the leaver so
nobody can forge one for someone else, and relayed by whoever receives it
so a partial delivery still converges.

A graceful leave does something the other two doors cannot: the leaver
takes part in one final re-share before disconnecting, handing their
seat's future to the survivors directly instead of leaving them to
reconstruct it. That is a real reason to make Leave easy and obvious
rather than buried — the polite exit is also the cheap one.

**Boot.** Every seat plays against a clock, and the clock is a bank,
not a limit per card. Each decision has a grace that costs nothing —
six seconds for a card, twenty for the pass, since there are thirteen
cards to read first — and each hand a bank of forty-five seconds of
thinking time that the part of a decision past its grace drains. Once
a seat's bank is empty and the grace on its current decision is spent,
a Boot button appears next to that seat. The first person to press it
removes the player. A player who thinks hard over three cards is never
bothered; one who takes fourteen seconds over every card is bootable on
their sixth. The bank refills every hand. The deal's own turns and the
audit, which a present device answers by itself, keep a fixed fifteen
seconds.

Nothing shows while a seat is within its grace. Past it, that seat's
remaining clock shows on its badge, and on your own score line when it
is yours, so you know you are spending it; at empty, the button.

The button is a **trigger, not a vote.** The condition is objective — the
turns opened at known game states and took what they took — and every
peer keeps its own account of each seat's bank from the turn timings
it observed. Peers' accounts differ by the network's tens of
milliseconds a turn, so a boot broadcast is countersigned by the others
within a second, once each one's own clock agrees. First press wins,
and the protocol underneath is still unanimous.

A peer that holds a signed play for that seat and turn must **rebroadcast
the play instead of countersigning.** That covers the case where the
player did act and one peer missed it, and it makes the boot attempt the
repair mechanism for a dropped message. Same rule gives the tiebreak for
a play at 14.9 seconds: a valid signed play for turn T voids any boot for
turn T.

The player being booted sees their own countdown. Someone on a bad
connection who is genuinely present deserves to know.

**Timeout.** Transport-level disconnects (WebRTC surfaces these within a
few seconds) plus an application heartbeat for the connected-but-wedged
case, which is usually a backgrounded tab.

This one matters more than it looks. A silent player who has not yet been
evicted **still counts toward every majority**: two silent seats out of
four leave the other two unable to decide anything, and once the bots'
moves are computed jointly a silent seat blocks those too. Someone
pocketing their phone during another player's turn is enough to wedge
things. The timeout is what prevents that, so it is load-bearing rather
than hygiene.

Longer than the boot clock — two minutes of silence against a bank
that a stalled seat empties in under a minute — so an active table
always resolves through the visible, explicable path and the timeout
only catches what boot cannot see. It was thirty, until a phone that
switched apps for a moment came back to find a bot in its seat; a
table that finds two minutes too long has the Boot button once the
bank is spent.

All three doors produce the same event: **"seat N is out as of game state
S."** One code path for the consequences, three ways in.

They differ in what backs the event. A signed Leave is evidence and
needs nobody's agreement. Boot and timeout are *inferences* about
someone's absence, and an inference needs **a strict majority of the
last agreed participant set** behind it — three of four, two of three.
At two humans no majority exists among the players, and that case goes
to the jury, below.

There is no rejoining. Without persistent identity there is nothing to
rejoin as, so a removed player goes back to matchmaking.

## Agreeing that somebody left

Hearts is turn-based, and that dissolves most of what would otherwise be
a hard problem. Exactly one seat may act at a time and the order comes
from the rules, not from who spoke first. The one genuinely concurrent
question is whether the seat on turn is still there, and the protocol
in `packages/table` treats every turn as exactly that question.

**A turn is a race with two sides.** On one side the seat's own action —
its pass or play, signed by the seat — and on the other its removal: a
boot, pressed by someone once the seat's clock has run out, or made at
once by a peer that has not heard from the seat for two minutes. Every other
participant backs one side or the other with a signature, never both,
and a side wins with a **strict majority of the participants at that
turn**. Only then does the next turn open, so nothing is ever rolled
back. A signed Leave is evidence and needs no majority.

**Silence is answered at the seat's own turn, and nowhere else.** A
peer that has heard nothing from a seat for two minutes boots it the
moment its turn is open, without waiting on its clock; the removal is
the race's own decision, and a seat removed that way has no later votes
for anyone to disagree about. What it cannot do is remove a silent seat
*before* its turn — and a silent seat still counts toward every majority
meanwhile, so someone else's contested turn can be stuck for want of its
vote. That turn goes to the jury, as a deadlock. The alternative was
tried: a claim that the seat was gone as of whatever position the
claimant stood on, backed by others, shrinking the majority for the turn
in progress. A thousand random walks showed why not. Peers apply such a
claim to an open turn at different moments, and two claims in flight at
once — each about a seat that had voted at that turn — let two peers
settle the turn opposite ways, each with a majority of the set it
believed in. No local rule closes that; agreement on who is present is
the jury's job, and the protocol only ever removes a seat where its own
race decides it or its own signature says so.

**The majority rule is what stops a partition becoming a fork.** Split a
four-human table 2–2 and each half sees the other as silent — but each
half holds two of four, neither has a majority, neither evicts anyone,
and neither is connected to a majority, so neither so much as claims.
Both halves wait, and when the network heals, whoever still holds
unsettled evidence repeats it and whoever is ahead hands the others the
whole decision they missed. Split it 2–1 and the two proceed correctly;
the one learns it is out when the network heals, and goes back to
matchmaking.

**Hearing is direct, or fresh, and a peer behind is carried forward.**
A peer counts as heard from when it sent something itself, and when
its own signed work arrives for the first time at or past where the
hearer stands — a play it made at this turn, however it was carried.
Not a relayed copy of something already seen: peers relay each other's
events when catching someone up, and before that distinction three
live peers re-sent a crashed seat's old witness to each other every two
seconds and each took it for a sign of life, forever. The other half of
the rule came from a real table where one seat reached one peer only
(its channels to the other two never opened and its relay subscription
had gone quiet): the two that heard it only second-hand booted it at
its turn, the one that heard it witnessed its play, two against two,
and the table split for a jury that does not exist yet. A heartbeat
says where its sender stands, and a peer that is behind hears back the
turns it is missing, a few at a time, without having to ask — which is
also how a peer learns of a leave it never received, since every
departure in the record travels with every answer. Catching up is
budgeted, a dozen events a second, and one peer at a time — the lowest
key among those present answers a heartbeat, the others only once the
asker has stayed behind through two more; a seat already removed is
carried only as far as the turn that removed it, and only every ten
seconds; and a split race repeats its evidence every half minute, not
every two seconds. Unbudgeted and unshared, two peers carrying two
others forward sent a public relay forty events a second between them,
and a phone that had been booted and kept sending its old position was
answered with the whole record by everyone, forever.
And a relay subscription that stops delivering without closing looks
like a quiet table, except that a peer's own events come back on its
own subscription; nothing at all for twenty-five seconds after
publishing means the subscription is dead, and the socket is dropped
and remade.

**The record is the belt and braces.** Every settled turn and every
departure goes into it with the signatures that carried it, in an
order every peer arrives at independently, and anyone can replay it
against the deal with the same rules: every human action signed by the
seat's key and legal, every removal carried by the participants of its
moment, every bot move recomputed, every majority checked against a set the
peer could legitimately have measured against. The departure matrix in
[doc 06](06-service.md) runs all of this on a simulated network on
every commit, and a chaos test walks the same simulator through random
faults checking that no two survivors ever disagree.

## Playing a seat nobody holds

A bot seat holds thirteen secret cards. Somebody must be able to open
them or the bot cannot play — and nobody may learn them.

Both are satisfied by **secure multi-party computation**, and the
distinction that makes it work is that computing on a secret is not the
same as reconstructing one. The hand goes in as fragments that are never
reassembled; the computation runs the bot policy over them and outputs
one card. Only that card leaves, and it was going face up anyway. So the
survivors collectively hold a departed hand and individually know
nothing about it.

**What goes in.** Not the ciphertexts. Decrypting inside the computation
would mean elliptic-curve arithmetic gate by gate — hundreds of millions
of gates per card — and the count below is what rules that out. Instead,
at the deal, once a player has opened their thirteen cards, they
secret-share the *plaintext* — which card sits at each of their thirteen
positions — among the other three players and a juror, alongside a
share of their decryption key. Each fragment on its own is random noise;
only all of them together are the hand, and they are never put together
in the open. The three other players, colluding, still hold noise
without the juror's piece, and the juror releases it only when the jury
has agreed the player is gone. Then the fragments feed the policy, and
the key shares let the survivors open a position in public, each
contributing its part of the decryption without anyone reassembling the
key. The policy answers with a position, the survivors open it, and the
card that appears is the play. Nobody sees a hand: not one player, not
all of them.

A leaver who shared a false hand is caught, not accommodated. The bot
plays from what it was given, the opened card is what was really there,
and at the end of the hand — when every hand is revealed for the audit
[doc 03](03-fair-deal.md) describes — the two disagree, provably,
against a player who already took the rating loss for leaving. Until
then the worst case is one bot playing the cheater's own seat a little
wrong.

**As built, for now.** The escrow is built — a piece of each person's
deal secret with every other person and every juror, and any one of
each rebuilds it (doc 03, "Escrow") — and what it opens is the whole
hand, to every survivor, for the bot to play in the open. The
computation over fragments that never meet is the design this section
describes and the next step; the leaver's false hand is caught the
same way either way, since the secret rebuilt is the secret the deal
was made with.

**What the next step costs**, since a design that is not built should
say. The policy is done: the circuit below is written, checked against
the bot, and counted. What is missing is the machine that runs it
without either party seeing an input, and that is not a small thing.

- **The protocol.** Two computing parties at most tables, three or four
  where more people are seated. Authenticated garbling (Wang, Ranellucci
  and Katz, [*Authenticated Garbling and Efficient Maliciously Secure
  Two-Party Computation*](https://doi.org/10.1145/3133956.3134053), CCS
  2017, and its multi-party companion) is the standard answer for two,
  and the same construction generalises, at a cost that grows with the
  parties, to more. Both are maliciously secure against any number of
  corruptions, which is the only setting that counts here: every party
  is a player with a stake in the hand, and a modified client is the
  threat model the whole of doc 03 is written against.
- **The size of a hand.** 53,726 AND gates for a bot-held seat over a
  pass and thirteen plays, measured below. Online that is two ciphertexts
  a gate, about 1.7 MB, which travels while the previous hand is played.
  The cost that decides the design is not there but in the
  preprocessing: one authenticated triple per AND gate, made by
  oblivious transfer, which is where the traffic and the seconds go.
  **The budget for it is measured**
  ([measurements/channel](../measurements/channel/README.md)): a hand is
  p50 a minute, a seat on a phone should be assumed to have a few
  megabits a second, and the two together give **about seven hundred
  bytes a gate**. And so is the triple
  ([measurements/ot](../measurements/ot/README.md)), built as WRK17
  describes it and checked against its own equations: **772 bytes and
  191 µs in wasm**, which is 24 extended transfers and 144 block cipher
  calls. Half that wire is the authenticated bits, which cost one
  transfer each and nothing more, and half is the check that they
  multiply. For a hand: **39.5 MB and ten seconds of a browser**, both
  parties' work. So it does not fit in a p50 hand on 5 Mbit/s — 66
  seconds of uplink for sixty of play — and fits in a p90 one with room.
  Two things move it, and both are worth taking. **Preprocess a game's
  worth rather than a hand's** and the bucket the protocol needs drops
  from four to three past 280K triples, which is about six hands: 579
  bytes a gate, 29.7 MB, 50 seconds, inside the minute. And **a
  table-driven field multiplication for the extension's check** is more
  than half the browser's time: without it a hand is 4.7 seconds rather
  than 10.3. What the browser pays for otherwise is AES, thirteen to
  forty times slower without the instruction a core has.
- **What it must not share.** The same measurement says where the
  material goes: not down the channel the table plays on. A seat that
  hands a hand's worth of preprocessing to the stack and then has to
  play a card waits behind its own upload — 8 MB of queue is 13 seconds
  on a 5 Mbit/s link — and the table boots it for silence. A channel of
  its own costs the table about 15 ms of added round trip while it runs,
  which is affordable; the queue has to be paced as well as separated.
  **Taken together the two numbers say the constraint is the shape of
  the traffic, not its size**: a hand's preprocessing fits, and fits
  several times over, so long as it goes out paced and beside the table
  rather than in front of it.
- **The party that has no channel.** A juror is not a peer. It is
  summoned, it follows the table from the relay alone
  (`juror_duty.dart`), and the app's transport offers a data channel to
  the human seats and to nobody else (`mesh_transport.dart`). So the
  foreman — which at one human is the second computing party — would
  compute over a relay, and a relay is not a channel. Material that is
  not text is base64 into the message, sealed to the foreman because a
  relay is a stranger's machine, and base64 again: **1.79x on the
  wire** against 1.0 down a channel, with one sealed event carrying
  49,143 bytes because NIP-44 caps a plaintext at 65,535
  ([measurements/relay](../measurements/relay/README.md)). The seconds
  are affordable — a millisecond an event to sign and about as much to
  check, at each end — and what the expansion costs is the budget:
  **a minute of 5 Mbit/s is 390 bytes a gate over a relay where it was
  700 over a channel**, and the relay is one queue for everything on
  the tag, so bulk on a second socket still costs the table's own
  messages ten times idle. Measured against the triple above, that
  settles it: 772 bytes a gate sealed at 1.79x is 74 MB and **119
  seconds** for one seat's hand, a whole p90 hand and nothing like a
  p50 one; at the smaller bucket a batch of a game's worth allows, 56
  MB and 89 seconds. So a foreman on the relay works only at the pace
  of a slow hand, and making it comfortable means giving a juror a
  channel — an offer, an answer and a candidate, exactly as a peer gets
  — rather than changing the protocol.
- **Where it would live.** Beside the deal. `crypto/deal` is one Rust
  crate built twice, a cdylib for the VM and a wasm for the browser, and
  garbling and transfer belong in the same place for the same reason.
  Dart drives it as it drives the deal.
- **What it moves at the table.** Each person would share the plaintext
  of its thirteen positions and a share of its key at the deal, beside
  the escrow it already shares; every departure would re-share among who
  is left, one hop ahead so the table does not stall on it; the foreman
  would become a computing party at one human; and a hand would gain a
  state for waiting on material, of the kind the table already has for
  waiting on escrow.
- **What must not be built.** A semi-honest version. It would look like
  this guarantee and would not be one: semi-honest security assumes
  nobody has modified their client, which is exactly what is assumed
  false everywhere else in these documents. Better the open hand above,
  which at least says plainly what it does.

**The policy as a circuit.** `packages/engine/lib/src/oblivious.dart` is
the bot rewritten without a branch on secret data, and its test proves
it picks the same card as the bot on every decision of forty games.
Counted, in AND gates — what a garbled circuit costs; XOR is free:

| | AND gates |
|---|---|
| one play, legality included | 2,237 |
| the same, hand in as thirteen dealt positions and position out | 3,316 |
| one pass | 10,618 |
| a bot seat for a whole hand: one pass and thirteen plays | 53,726 |

About half of a play is the run at the moon — knowing which cards are
sure winners takes the whole played set as public input. At two
ciphertexts per gate a play is about 110 KB and a whole hand under 2 MB;
malicious security multiplies that by a small constant. Small enough
that the material for a hand travels while the previous one is played,
and that the precomputation below is seconds of background work.

**The parties are the humans at the table, and only them.** Adding the
service as a third party would buy a cheaper protocol — honest-majority
protocols are far faster — but it would also mean the service colluding
with one player could defeat another, and that coalition excludes someone
who gets hurt. Keeping the parties to the humans means any coalition able
to open a hand contains every human at the table, and then there is
nobody left to defraud. That is the same guarantee the deal itself makes.

The parties shrink with the table, down to a floor of two:

| Table | Who must not see bot hands | Parties |
|---|---|---|
| 4 humans | no bots exist | — |
| 3 humans + 1 bot | each human | the three humans |
| 2 humans + 2 bots | each human | the two humans |
| 1 human + 3 bots | the human | the human **and the foreman** |

A lone human is never a lone party. The foreman — a stranger drawn at
random from elsewhere, with no stake in the table — takes the departed
player's place as a computing party, so the survivor never holds a bot
hand and cannot see one, however their client has been modified. That
is what makes [doc 03](03-fair-deal.md)'s guarantee unconditional.

Departures require re-sharing among the survivors, and the material for
the next configuration is precomputed one hop ahead so a departure does
not stall the table. Preprocessing is input-independent — it reveals
nothing and cannot be opened — so it is safe to distribute in advance,
which a hand would not be. Hand fragments are re-shared one hop ahead
too, and the piece that lets the survivors carry on without a departed
holder goes to the jury, never to a survivor: survivors holding enough
between them to continue without someone could open the hand without
them as well. If two people go inside the same window the table pauses
for a beat while it catches up; that is a moment to design, not an
error.

## Why there is no service in any of this

The bot is deterministic and its policy is public. The deal is committed
at shuffle time — the encrypted deck and the seat assignments are public
and signed by all four players — so every hand is fixed and unforgeable
from the deal onward even while hidden.

Together those mean **a bot's play is a computable consequence, not a
claim anyone has to be believed about.** When the hands are revealed at
the end of a hand, anyone can recompute every bot play and check it.

The same argument covers human plays: each must be a card from a
committed hand and legal under the rules. So the whole game record
verifies end to end, by anyone, against the committed deal. A forged
chain does not need to be prevented — it fails the check.

Which is why there is no witness, no arbiter and no server in the game.
Not as a principle we are defending, but because the determinism of the
bot and the commitment of the deal make one unnecessary.

## The jury

Two of the cases above cannot be settled by the players alone. At **two
humans**, a silent player leaves the other with one vote of two — no
majority, and from the inside a rage quit and a partition look the same.
At **one human**, there is nobody to be the second MPC party. Both need
one thing: a party with no stake in the table.

So every hand seats a **jury**: a small number of players drawn at random
from whoever is online at other tables. Each juror holds a share of the
hand's key material — useless alone — and connects to all four seats at
the start of the hand. One is **foreman**, chosen by the deal's own
randomness (which every party has already verified), with the others in
a deterministic order behind them.

**Random, not ranked.** Any selection criterion an attacker can optimise
becomes a lever, and uptime or latency are trivially optimised by running
a node. Random draw from purchase-backed identities offers no lever; a
juror with a bad connection is simply disqualified and redrawn. Random
selection across unrelated networks also keeps juror failures
independent, which the sizing below depends on.

**Per hand, not per game.** The deck is resealed every hand, so shares
are per-hand and a juror's whole obligation is one hand — p50 a minute,
p90 two. Short enough to ask of a stranger, and short enough that an
attacker who does get selected has a couple of minutes of relevance.

**The tiebreak.** At two humans, A reports that B has gone silent. The
foreman checks for itself: it connected to B at the start of the hand and
knows whether that route still works. If B is reachable, A is told to
wait — it is a partition, not a departure. If not, B is gone. A rage quit
is offline from every juror's perspective, so every juror agrees and the
survivor continues. Only a partition that also splits the jury can
produce two answers, and that degrades to a detectable fork rather than a
silent one.

**The second party.** At one human, the foreman steps into the MPC in
the departed player's place. Survivor and foreman compute each bot move
together, for the rest of the hand, and neither sees a card. If the
foreman drops, the next juror in order already holds the share and takes
over at the next move.

**Size.** The jury fails only if every juror leaves inside one
replacement window — the ten seconds or so it takes to notice a drop,
redraw, and distribute a share. With sessions of one game and a p90
two-minute hand, four jurors put that around 10⁻⁵ per hand; with
players staying for two or three games it is nearer 10⁻⁶. **k = 4**,
and the number to make small is the replacement window, which enters
as (λT)ᵏ. Halving it is worth more than a fifth juror.

**If the jury is lost anyway**, the table pauses, says so, and resumes
when one is rebuilt. Nobody at the table controls whether strangers
elsewhere go offline, so the pause is not a lever.

**Juror of last resort.** When a table cannot draw a jury — because too
few people are online — it says so, and a client we manage comes online
to serve. It is the same code every other juror runs, holds the same
kind of share, does the same one hand, and knows nothing else. Its cost
scales inversely with the player base: it runs when the room is empty
and never otherwise. This is the only place a gameplay event reaches
anything of ours, and what it carries is "a table needs a juror."

**The draw is verifiable.** The four at the table agree a snapshot of
who is online, and apply the deal's own randomness to it. Nobody at the
table can steer the draw, and nobody outside it can either.

### As built

The jury's deadlock role is built (`packages/table`: `jury.dart`,
`juror_duty.dart`, `presence_relay.dart`, and the client's "the jury"
section), and its escrow role ([doc 03](03-fair-deal.md), "Escrow").
On the wire:

- **Presence.** Every open app announces itself on one topic every
  five seconds — written to every relay, listened for on all of them
  — and keeps who was heard when. A summons is an event on that
  topic addressed to one key, carrying the table's spec and the hand.
  A juror follows the table on its own relay list, so a table on
  relays a juror does not listen to has no jurors from that pool.
- **The draw.** At each hand the lowest key among the participants
  heard lately proposes: a snapshot of who is online (nobody at this
  table), and the draw — four, foreman first — as a deterministic
  function of the seed, the hand and the snapshot. The others witness
  it when the draw is what the snapshot gives and the jurors are people
  they too have seen; a majority carries it, beside the record rather
  than in it, since two peers may hold different evidence for the same
  authority. Everyone summons the jurors. A jury stays in force until a
  later one carries: a table of two with one gone quiet cannot carry a
  new one, and that is when it needs the old. A jury gone quiet is
  redrawn from whoever is left; with nobody online to draw from the
  table says so and calls for a juror of last resort.
- **The juror** follows the table like any peer behind — a summoned
  client is carried forward by the same heartbeats — and heartbeats
  while it serves. On the relay alone: a juror is not seated, so
  nothing offers it a data channel, and everything it hears and says
  crosses two hops and a stranger's machine. What it does today is
  small enough for that not to matter, and the computation above is
  the first thing that would.
- **The appeal.** A stuck turn — a race that split, or any open turn
  while the table is paused — is appealed every ten seconds.
- **The rule.** A juror rules only when nobody who can still vote, as
  far as it can hear, could carry either side: votes that may yet come
  are carried, not overruled. Then by the seat's presence to it — heard
  and acted, the action stands; silent, the removal stands, on a boot
  someone made or on the juror's own claim of absence. Heard and not
  yet acted is nobody's to decide. A seat named by an appeal or a boot
  says its action again on every relay, so a juror that cannot read
  the relay it wrote to hears it before ruling. The foreman rules first; each juror
  behind waits five seconds more. A verdict carries the winning event
  whole, so it settles the same turn the same way wherever it lands,
  and a turn settled by verdict travels with its verdict when a peer
  behind is carried forward.
- **Carrying.** From the first appeal of a hand to its end, the first
  juror in the draw still heard from says again at once everything it
  hears for a turn not yet settled: a table cut in two has its votes on
  both sides, and the juror hears both. The cut table then runs at its
  own pace rather than an appeal's, and no verdict is needed.
- **The verifier** checks each jury against its snapshot and its
  majority, and each verdict against the jury in force for the hand,
  the turn, the seat and the very event recorded.
- **Escrow.** At a sealed table a juror holds a piece of each
  person's deal secret ([doc 03](03-fair-deal.md), "Escrow"), given
  with the person's keys, and releases it when the table removes the
  seat — with a person's piece, the seat's hand opens for its bot.

The simulator's jury rows (`packages/table/test/jury_test.dart`): a
table of two with one gone quiet off turn and on it; four cut two and
two with the jury reaching all; the foreman crashing; the whole jury
going quiet; nobody online and a juror of last resort; nobody online
and none. The chaos walk draws four jurors and lets them go too, and
ends every seed finished, or paused only with no juror left up. The
browser suite runs the two-person case over real sockets against the
service's juror of last resort.

## What the jury does not change

Everything a juror holds is a share. A juror alone can open nothing.
Together with a player at the table, a juror can help play a seat that
seat's owner abandoned — and that is the whole of it. To break a hand
you need a juror colluding with a player at that specific table, which
means being drawn at random for it, for the one hand it matters, and
having arranged the collusion in advance. Bounded, and expensive to
target.

## Scoring

Each game produces a record: the committed deal, every signed play, and
the revealed hands. Ratings are computed from that record by anyone; no
authority holds them.

Two rules:

- **A bot in the winning seat means nobody's rating moves.** A win by a
  seat its owner abandoned is not evidence about anybody, and the players
  who stayed should not be marked down because a bot beat them.
- **A live player winning moves everyone**, up for them and down for the
  other three, including anyone who left.

Leaving is therefore never an escape and never an upside. There is no
abandonment penalty to calibrate, which matters because **a rage-quit and
a dead battery are indistinguishable** and any explicit penalty would
land on both.

Nobody needs to sign a result. The scores are a deterministic function of
the signed play chain, so there is no end-of-game ceremony for a leaver
to withhold — which would have handed a veto to exactly the player most
motivated to use it.

## Presence and matchmaking

There is no presence server. Every online client publishes a signed,
short-lived event to a well-known relay topic every few seconds —
*identity, status, region* — and everyone subscribes. At hundreds online
that is a few dozen tiny events per second per client.

**Forming a table** is the one place eventual consistency bites: seekers
see each other through relays that deliver in different orders, so two
seekers can compute different groupings. The rule is time-windowed
batching. Everyone who announced in the same short window groups
deterministically by sorted identity. No rounds, no votes. If your
group-mates saw a different set, the connection fails and you fall
through to bots — a split brain degrades to "you got bots" rather than
to a hang. Costs a second or two inside the ten-second window.

**One device at a time** is cooperative here: a newer attestation
appears on the topic and the older device signs itself out. An honest
client does; a modified one could ignore it and be at two tables at
once, which random matchmaking makes hard to turn into anything.

What decentralising presence buys is that the game keeps working if we
vanish. What it costs is the second or two above and the honour-system
device rule. Fairness was never at stake either way — a presence server
could refuse to match you, but never see a card.

## Identity

An identity is a keypair generated on the device, in Nostr's format. The
public key is what appears in every public record — plays, ratings, jury
draws. It is opaque, and nothing links it to who you are.

**Sign-in attests it.** Live play needs Sign in with Apple or Google.
The service verifies the token, checks that this provider account is not
already bound to a different key, and issues a signed attestation:
*"this key is backed by a provider account."* Not which one. The
provider's identifier never leaves the service, and no email is stored
at all — neither of our uses needs one.

**Losing a device is a supersession.** Sign in on the new one, generate
a fresh key, and the service — seeing the same provider account — signs
*"new key supersedes old."* Ratings and entitlement attach to the chain,
so everything follows you. Within a platform the key syncs through the
keychain and nothing is needed; a cross-platform move is a supersession.

The player sees none of this. Sign in, and you have an identity. There
is no key to look at and no export — the word Nostr appears nowhere in
the app.

## What the service does

Five stateless handlers and a small key-value store:

| | |
|---|---|
| attest | verify a sign-in token, enforce one provider account per key, sign the attestation |
| supersede | same sign-in, sign the supersession link |
| entitle | receive the purchase webhook, mark the key entitled, issue a signed licence |
| turn-creds | mint short-lived TURN credentials |
| last-resort | bring a juror online when a table reports it could not draw one |

It never holds a card, never signs a play, never adjudicates anything,
never sees who is at which table, and is not required by a table already
in progress. Every handler is a point lookup and a signature.
[Doc 06](06-service.md) has the storage, the local mode, and the layout.

## Still open

- **Chat.** None. Text between strangers is a moderation surface and
  Hearts does not need one. Whether a fixed set of table gestures earns
  its place is worth revisiting.
- **Collusion.** Two players sharing hands out of band beat everything
  here. With nothing at stake it is small; it is a reason not to give the
  game stakes.
