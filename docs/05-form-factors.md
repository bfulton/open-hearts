# 05 — Screens

The web build and the app builds are the same product. Where they differ,
the difference comes from the screen in front of the player and nothing
else — not the platform, not the store it came from.

That is a design constraint with teeth: no feature exists on one and not
the other, and no layout is written for a device. The table is laid out
from the size and shape of the space it is given.

## What has to work

| | Roughly | Notes |
|---|---|---|
| Phone, portrait | 390 × 844 | Where the game is settled first |
| Phone, landscape | 844 × 390 | Equally first-class, and a different composition — see below |
| Tablet | iPad, Android tablets | Not a stretched phone. See below |
| iPhone Duo, closed | 5.4″ | A phone |
| iPhone Duo, open | 7.6″ | A small tablet |
| Desktop web | anything | Windowed, resized mid-game, very wide |

## Portrait and landscape are both the game

Not "portrait, and landscape works too." A phone on its side is how a lot
of people hold a card game, and the game has to be as good there.

They cannot be the same composition, though, because **their scarcities
are opposite.** In portrait, width is what runs out: thirteen cards have
to fan across 390 points, which is what forces the overlap down to a
~24-point sliver per card. In landscape there is 844 points of width and
the fan is comfortable — but only 390 points of height, and the current
chrome (score strip, action line, hand) eats 236 of it before the table
gets any.

So landscape is not portrait squeezed. **The score strip becomes a side
rail.** Moving it off the top buys back the height the trick needs, and
it has somewhere to go, because width is the thing landscape has spare.
The hand keeps the bottom edge, near the thumbs, with wider and shorter
cards — more of each card visible, less of it tall.

That is two compositions, chosen on aspect ratio, sharing every widget
below them. It is not two layouts to maintain so much as one layout with
the score rail on a different edge.

Rotation mid-hand must keep the game, exactly as unfolding must.

### As built

`app/lib/ui/table_layout.dart` chooses: wider than tall by a fifth is
landscape, so a near-square window is laid out as portrait, where the
fan is what needs the width. The side rail above was built and then
taken out again, because the score chrome it moved turned out not to
be needed on either edge: an opponent's total now sits on their badge
beside what they have taken this hand (their card count is gone — it
is the same as yours), and your own total and hand sit on one line
with theirs.

That line is the fourth seat, on the felt with the other three, in
both compositions. All four badges are the same widget and each is
the same gap from the card it labels — eight points at a phone's
scale, on all four sides, at every shape — which is what makes a badge read as that card's label rather
than as furniture along an edge. They are placed against the trick,
not against the felt, so the felt's spare height is rail around the
table instead of distance between a seat and its card; and because
the badges hold to their cards, the trick is sized from the height
they leave rather than the other way round, which is why nothing
overflows when a name wraps or the reader turns the text up (a badge
scales its contents into its box).

Every badge hugs its name, up to the room it has — the width of the
trick's own column for the two facing each other across it, the strip
between a card and the felt's edge for the two at the sides — and each
pair comes out one size: the two are each laid out over a ghost of the
other, which takes up its room and draws nothing, so whichever name is
the longer, the pair match. A side badge is anchored by its inner
edge, that gap out from its card, and runs towards the felt's edge
as far as its name takes it. The badges used to fill their room, so a
short name sat in a wide bar and a side seat in a tall box, and a
tablet stretched them wider still.

The trick's four places keep their room and draw nothing until a card
lands in one. They used to draw a faint outline each, four rules on the
felt before anything had been played, and a trick reads as a trick
without them.

The two lines under the table say different things and sit where each
belongs. What the table says — who took the trick, or that it is your
turn — floats in the middle of the room the felt keeps under the
player's badge, which is sized for it twice over so it is never
against the badge. The action line is about the hand — what you were
passed, how many more to choose — so it sits against the hand, in a
row of the height of its tallest state, the pass, whatever it is
holding: the table above it never shifts when the line changes. And it
is as wide as a whole hand's fan and the margin round it, centred over
it, so its ends — the note at one, the Pass button at the other — line
up with the fan's. On a phone upright the fan takes the width and so
does the line; anywhere the fan is narrower than the table, the line
used to run past both ends of it. A wide
felt has no height for the table's line at all, and plenty of width,
so there it sits beside the player's badge, with the same room kept on
the other side so the badge holds the middle. What is left
along the top is a header 40 points tall in both compositions — the
menu on the left, the hand and the pass in the middle, and on the
right a heart, whole until hearts are broken — so the two compositions
differ only in the hand: 100 points tall instead of 128, its fan
stepping up to eight tenths of a card instead of two thirds, so
shorter cards show more of themselves. On a wide felt the trick lies
flatter — west and east further out, north and south closer in — and
the seat badges go to one line, which is what gives the trick its
height back. Both the solo table and the live one are built on it.
Widget tests run the phone on its side (844 by 390): the header, a
hand fitting, a whole hand played out, and a turn mid-hand that keeps
the same controller, hand, trick and totals on both sides of it.
`node e2e/shots.mjs` screenshots the built app at the shapes in the
table above, the pass and the first trick each, for looking at a
layout before a phone does — the tablet and the Duo among them now.

## The foldable is easier than it looks

Apple's [iPhone Duo](https://www.apple.com/iphone-duo/) has a 5.4″ Super
Retina XDR outer display and a 7.6″ folding inner one, and — the fact
that matters — **both share the same aspect ratio.** So unfolding is a
change of scale, not of shape. The layout does not have to reflow into a
different composition the way it must on foldables whose cover screen is
a different rectangle.

Two smaller gifts: the FaceTime camera is under the display, so the inner
screen is a clean rectangle with no cutout to lay out around; and the
inner display carries a nano-texture finish, which means the table's dark
felt will hold up under a lamp rather than turning into a mirror. The
felt was chosen for looks — it turns out to suit the panel too.

Two things still have to hold:

- **Unfolding mid-hand keeps the game.** The fold is a resize, and a
  resize must never cost state. Worth an explicit test, because the
  usual way this breaks is a widget rebuilding a controller on a
  constraints change.
- **Split View gives the app half a screen.** iOS 27 puts two apps side
  by side on the Duo. Half of 7.6″ in portrait is narrower than any
  phone, so whatever the layout does at its narrowest has to be the
  thing it does there — which is the argument for sizing from
  constraints rather than from a device list, again.

## A note on the chip

The Duo runs an A20 Pro with a 7-core GPU and Neural Accelerators. That
does not change a card game's rendering budget by any amount worth
discussing — but it is a useful upper anchor for
[doc 03](03-fair-deal.md)'s open question, which is whether a verifiable
52-card shuffle is fast enough in wasm on a phone. When that gets
measured, it should be measured on something mid-range and old, not on
this.

## Tablets are not big phones

The phone layout scaled up is the classic tablet failure: enormous cards,
acres of felt, and a hand fan you have to reach across the device to
touch. A tablet has enough room to show more of the game rather than more
of the same game — the trick tidily in the middle at a sane size, and the
space around it earning its keep with what a phone has to hide, like the
running trick history or what each player has taken.

The hand should stay near the bottom edge and near the thumbs, which on a
tablet in landscape means it does not want to be one wide fan across the
full width.

**As built.** Four things, all read off the constraints.

*The table holds a width.* Past nine hundred points it stops spreading,
because a fan any wider is a fan you reach across the device to touch.
Whatever is left over is a rail, when there is enough of it to be one
— two hundred and sixty points — and no more than four hundred and
twenty, past which a rail is a column of air and the table would rather
have the width back. A tablet in portrait has a hundred and twenty-four
points left over, so it gets a wide table and no rail; in landscape it
gets both. The table and its rail are one composition, centred
together, so on a screen wider than both the margins either side of
them match; the table used to be centred in what the rail left, with
the rail against the screen's edge.

*The cards grow with the felt.* Seventy-six points was a phone's cap,
and a phone's cap on a tablet is a phone's game with green around it.
The cap is now seventeen hundredths of the felt's own shortest side,
between seventy-six and a hundred and eight: a phone lands exactly
where it did, and a tablet's trick comes up to a size you can read from
across a desk. The hand's own row grows a little too, since it is the
part anybody touches.

*The type grows with the cards.* The names on the badges, the line the
table says, the action line and its Pass button, and the rail were a
phone's size on every felt, so a tablet had a big game with small words
on it. Now the table has one scale — how much bigger than a phone's its
cards may be, up to a hundred and eight over seventy-six — and all of
that is drawn at it: laid out in that much less room and drawn that
much bigger, type, icons, padding and the gaps between together
(`app/lib/ui/scaled.dart`). The felt the scale is read from is the
one the layout leaves it, with the action line drawn at the scale
being found, so the layout solves for it. A phone's table is at
exactly one, and is drawn exactly as it was; the header, which is the
app's line rather than the table's, stays as it is everywhere.

*The table sits low in a felt with height to spare.* A phone's felt is
the size of its table and the slack is a few points either way, so it
is centred, as before. A tablet's has height the cards will never grow
into. There the room beyond the far seat reads as the far end of the
table, and the room under your own badge is the gap between you and
your own cards — so the first gets seven tenths of it and the second
three.

What the rail carries is the first of the two this section named, and
the one a phone genuinely cannot show: **what has gone**. The
fifty-two, with the played ones faded and struck through, and the line
underneath that nobody does correctly in their head — how many hearts
and whether the queen is still out. Nothing on it is a secret; every
card on it was played face up in front of everybody. It is a memory
aid, not a peek.

`app/test/tablet_test.dart` holds the shapes, including the two this
document asks for by name: unfolding mid-hand keeps the game, and Split
View is the phone composition because nothing knows what a tablet is.

## What moves, and why

Movement on a card table is information. A card that simply appears
where it will sit says nothing about where it came from; a card that
travels says whose it is, and says it in the time it takes to look up.
So every card that changes hands travels, and it travels the way the
table is laid out — the near player below, then west, north and east
(`ui/table_view.dart`, `seatDirection`).

Four movements, one rule each:

- **A card played** rises out of the hand towards the table, and arrives
  in its slot from the side of the screen its player sits on. Dragged up
  and let go, it carries on from where the finger left it rather than
  dropping back into the row first. It lands the way a card played onto
  a table does: in fast and settling long, solid a third of the way in,
  and coming down onto the felt — a touch big and a few degrees askew —
  as it arrives. It used to fade up over the whole of its flight, which
  is how something appears, not how a card lands.
- **The three passed** leave the hand off the side of the screen the
  player they are passed to sits on, and **the three received** fly in
  from the side the passer sits on. Nobody has to read the arrow to know
  which way the hand went.
- **The finished trick** goes to whoever took it: the other three are
  gathered onto the card that took it and the pile is pulled off towards
  its taker, shrinking and fading as it goes. The taking card is the one
  furthest towards its taker, so every card still only moves the one
  way. It used to leave as a picture of four cards sliding off in
  formation, fading from the first frame.
- **The hand closes** over the gap a card leaves, and opens for one that
  arrives, rather than snapping to its new fan.

Each is eased by what it is doing, with the platform's own curves
(Flutter's `Easing`): what arrives decelerates — in fast, a long
settle — what leaves accelerates, and what moves within the screen, the
hand closing up or a card lifted for the pass, eases in and out. The
hand used to close at full speed from its first frame, so the
neighbours of a played card jumped. The one exception is a card leaving
the hand, which goes at speed from the tap, for the reason below.

The heart at the front door is the one thing that moves on its own,
and it does not move for long: it folds away and opens out over nine
seconds, and then is simply a heart until twenty seconds are up and
its turn comes round again. The first turn waits three seconds, so the
door opens on the heart whole and still; it used to begin its fold the
moment the page opened, so the first anybody saw of the mark was it
leaving. Between turns it asks for no frames at
all, which is the difference between a flourish and a fidget on a door
somebody leaves open in a tab.

Two of these begin at the tap that asked for them, not at the frame
after. A controller's first tick is the next frame, so a flight started
from nothing spends its first drawn frame exactly where the card
already was — a frame of nothing, which a hand still closing over the
gap hides and the last card of a hand does not. Both start a frame in.

At the end of a hand the sheet waits: the last trick sits while its
winner is named, sweeps away, and then there is a beat of bare felt
before the score comes down over it. A sheet that arrives on the tail
of the cards leaves the hand's last thing unseen and the number it is
about unexplained.

That beat is the one piece of pacing that is not an ornament, because at
a live table the hand under it is still moving. A screen shows the
record at its own speed, a step at a time; a beat kept by a timer beside
that walk is a beat the table can interrupt, and at a live table it
does — the next hand is dealt and passed while the screen holds, and
each decision heard while it holds is another reason to start the walk
again. So the beat is a step of the walk itself: the shown hand ends,
the screen waits, and then the sheet comes down and the next hand is
dealt under it. Nowhere the walk will not step past can the screen be
left standing.

None of it is long: a play is 240 ms, a pass 420, a trick swept 300, the
fan settling 220. A movement anyone has to wait for is a movement that
has stopped being information. And none of it is load-bearing — every
one is an ornament on a state the screen is already showing, so a device
asking for no animation (`MediaQuery.disableAnimations`) gets the same
table with nothing in flight.

## The picture somebody chose

A badge is sixty-four pixels across, so a photograph has to be cut down
hard, and taking the middle square is what a computer would do and is
wrong about half the time: people are not in the middle of their own
photographs. A head cut off at the chin is then the whole of what
anybody sees of them.

So the square stays put and the photograph moves under it. Drag to move
it, pinch to make it bigger, and what is in the circle is what is kept
— the circle, because the badge is round and it is better to see the
crop than to be told about it. The picture is asked of the phone at a
thousand pixels rather than two hundred and fifty, which is what a crop
zoomed right in has left to work with.

The arithmetic is `Window` in `ui/photo_crop.dart`, and it is a value
with no widget around it for one reason: it is the part that can be
wrong in ways nobody notices until they are looking at their own chin.
`app/test/photo_crop_test.dart` walks it before it walks the page.

## What the colours mean

One meaning each, and the one that matters is **gold: what you can
do**. A button, the card you may play, the seat it is the turn of, the
thing that is waiting on you. Nothing else wears it — and "nothing
else" is the whole rule, because gold on a name or a score or a rating
teaches the eye that gold means nothing in particular, and then it
means nothing when it is your turn.

So the things a game tells you are white: which hand ended, the row
that is yours, the rating you have, what a game did to it, the trick
somebody just took, the icon and colour you chose on your profile —
ringed in white, standing off the disc by a gap of felt so the ring
shows on every colour; it was gold, on the disc's own edge, which on
the amber disc was no ring at all. And one gold thing to press is the
most a screen has that it is for: the door's is Play solo, and
Subscribe, on the card that says what live play is, is drawn in gold
rather than filled with it — still something you can do, not the thing
the door is for. **Red is the game's own** — a heart, a suit,
points against you, the game that went the other way. A score sheet
ends up white over red with one gold button on it, which is exactly
what it is: this is what happened, and here is the way on.

`app/test/palette_test.dart` is where that is checked rather than
believed.

## Read aloud

The table is also a screen a reader moves through and a voice says, and
the way to know it works is to play it that way: a hand of solo played
with nothing but the browser's accessibility tree, every decision made
from what the tree said (done for the launch, in a headless Chromium,
by reading the tree and activating nodes by name as a screen reader
does). What it found, and what came of it:

- **The cards are there, by name.** "queen of spades", one node each,
  the unplayable ones disabled; the cards passed and received named on
  their line; who led and who played what on the felt. This was so.
- **Where everyone sits was not.** Pass left — to whom? A sighted player
  reads it off the felt; a listener had to work it out from who led and
  who passed. Each seat now says it: "Mark Antony: 0 in the game, 0 this
  hand, on your left", at the end of the line so that what a suite reads
  at its start is unchanged.
- **Who took the trick was gone in under a second.** The pill that says
  so is on the felt for the trick's hold, and nobody moving through the
  screen would find it in time. It is now said as it appears — "Mumtaz
  Mahal takes it, 1 point" — and so is "Your turn", through the
  platform's announcements (`Announced`, ui/table_view.dart), which a
  browser puts in an aria-live region.
- **The scores after a hand read as numbers without names:** "Psyche +11
  11", and a dash read as a dash. Each row is now one line: "Psyche: 11
  this hand, 11 in the game".
- **The profile button held a second button with no name in it**, the
  ink under the label. It does not any more, nor does the options
  button; `test/accessibility_test.dart` walks the front door's tree for
  anything tappable without a name.

Two things it found are not fixed. A card chosen to pass is marked
`aria-current`, which the web engine makes of a selected button and
which a screen reader says as "current" rather than "selected"; the line
under the felt counts down how many are left to choose, which is what
makes it playable. And the felt's cards are read in the order they are
drawn, not the order they were played — "led" says which came first, and
the order of play is now the order of the seats round from it.

## How the layout decides

One rule, applied everywhere: **size from the constraints you are given,
never from the device you think you are on.** No platform checks, no
device lists, no user-agent sniffing. The table already asks how much
room it has and picks a card size from it; everything else works the same
way.

Breakpoints, when they are needed, key on the shortest side and the
aspect ratio, because those are what actually change the composition. A
foldable opening, a desktop window being dragged narrower, and a phone
turning sideways are then all the same event, handled once.

## Order

1. **Phone, both orientations.** Portrait settles the game; landscape
   settles the second composition. Neither ships without the other.
2. **Desktop web** — the landscape composition with more room, plus
   surviving a window dragged to any size mid-game.
3. **Tablet** — the first layout worth designing rather than deriving.
4. **iPhone Duo** — mostly falls out of the tablet work plus the resize
   test, given the shared aspect ratio.

The through-line is that steps 2 to 4 keep being cheap only if the layout
never asks what device it is on. A window being dragged narrower, a phone
turning sideways, and a foldable opening are the same event.
