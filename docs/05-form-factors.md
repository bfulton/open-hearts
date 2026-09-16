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
eight points from the card it labels — on all four sides, at every
shape — which is what makes a badge read as that card's label rather
than as furniture along an edge. They are placed against the trick,
not against the felt, so the felt's spare height is rail around the
table instead of distance between a seat and its card; and because
the badges hold to their cards, the trick is sized from the height
they leave rather than the other way round, which is why nothing
overflows when a name wraps or the reader turns the text up (a badge
scales its contents into its box).

Each pair comes out one size. In portrait that falls out of the room:
the two facing each other across the trick are as wide as the trick's
own column, and the two at the sides take the strip between their card
and the felt's edge, and the height of that card. On a wide felt there
is no strip to fill and a box the width of the trick would be a bar
with a word in it, so a badge hugs its name — and the two of a pair
are each laid out over a ghost of the other, which takes up its room
and draws nothing, so whichever name is the longer, the pair match.

The two lines under the table say different things and sit where each
belongs. What the table says — who took the trick, or that it is your
turn — floats in the middle of the room the felt keeps under the
player's badge, which is sized for it twice over so it is never
against the badge. The action line is about the hand — what you were
passed, how many more to choose — so it sits against the hand, in a
row of the height of its tallest state, the pass, whatever it is
holding: the table above it never shifts when the line changes. A wide
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
layout before a phone does. Desktop web gets the landscape composition
with more room, as step 2 says; tablets and the Duo are not designed
yet.

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

None of that is designed yet. What matters now is not baking in the
assumption that it is a scaled phone.

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
  dropping back into the row first.
- **The three passed** leave the hand off the side of the screen the
  player they are passed to sits on, and **the three received** fly in
  from the side the passer sits on. Nobody has to read the arrow to know
  which way the hand went.
- **The finished trick** goes to whoever took it, all four cards the one
  way, shrinking as they go.
- **The hand closes** over the gap a card leaves, and opens for one that
  arrives, rather than snapping to its new fan.

The heart at the front door is the one thing that moves on its own,
and it does not move for long: it folds away and opens out over nine
seconds, and then is simply a heart until twenty seconds are up and
its turn comes round again. Between turns it asks for no frames at
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

## What the colours mean

One meaning each, and the one that matters is **gold: what you can
do**. A button, the card you may play, the seat it is the turn of, the
thing that is waiting on you. Nothing else wears it — and "nothing
else" is the whole rule, because gold on a name or a score or a rating
teaches the eye that gold means nothing in particular, and then it
means nothing when it is your turn.

So the things a game tells you are white: which hand ended, the row
that is yours, the rating you have, what a game did to it, the trick
somebody just took. **Red is the game's own** — a heart, a suit,
points against you, the game that went the other way. A score sheet
ends up white over red with one gold button on it, which is exactly
what it is: this is what happened, and here is the way on.

`app/test/palette_test.dart` is where that is checked rather than
believed.

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
