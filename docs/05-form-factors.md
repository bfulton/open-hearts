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
