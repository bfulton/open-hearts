# 05 — Screens

The web build and the app builds are the same product. The layout
depends on the space the table is given, never on the device. There are
no platform checks, no device lists and no user-agent sniffing. A phone
turning sideways, a foldable opening, Split View and a desktop window
being resized are all the same event: new constraints.

| | Roughly |
|---|---|
| Phone, portrait | 390 × 844 |
| Phone, landscape | 844 × 390 |
| Tablet | iPad, Android tablets |
| Foldable | a phone closed, a small tablet open |
| Desktop web | any size, resized mid-game |

Rotating, unfolding or resizing mid-hand never costs the game.
`app/test/tablet_test.dart` and the widget tests for the phone on its
side check this. `node e2e/shots.mjs` screenshots the built app at each
shape.

## Portrait and landscape

`app/lib/ui/table_layout.dart` treats the table as landscape when it is
more than 1.2 times wider than it is tall. A near-square window is laid
out as portrait, where the fan of cards needs the width. The two
compositions share every widget. Both have a 40-point header: the menu
on the left, the hand number and pass direction in the middle, and on
the right a heart that stays whole until hearts are broken. They differ
in the hand row. In landscape it is 100 points tall instead of 128, and
the fan steps up to eight tenths of a card instead of two thirds, so the
shorter cards show more of themselves. On a wide felt the trick lies
flatter and the seat badges fit on one line.

All four seats, yours included, have a badge on the felt. Each badge is
the same gap from the card it labels, on all four sides, so it reads as
that card's label. A badge shows the player's total and what they have
taken this hand. Each badge hugs its name, and the two badges of a pair
are laid out to the same size, so a long name and a short one match. The
trick is sized from the height the badges leave, so nothing overflows
when a name wraps or the text size goes up.

What the table says (who took the trick, whose turn it is) floats under
your badge. The action line (what you were passed, how many cards are
left to choose, the Pass button) sits against the hand, as wide as the
fan. Its row is always as tall as its tallest state, so the table above
never shifts.

## Tablets

A phone layout scaled up is the wrong answer: enormous cards and a fan
you have to reach across the device to touch.

- **The table holds a width.** Past 900 points it stops spreading.
  Leftover width of 260 to 420 points becomes a rail. With less there is
  no rail, and with more the table takes the width back. The table and
  its rail are centred together.
- **The cards grow with the felt.** The card cap is 0.17 of the felt's
  shortest side, clamped between 76 points (a phone's) and 108.
- **The type grows with the cards.** The table has one scale, from 1 on
  a phone up to 108/76. Badges, the table's line, the action line and the
  rail are all drawn at that scale (`app/lib/ui/scaled.dart`). The header
  stays the same size everywhere.
- **The table sits low.** On a felt with height to spare, seven tenths
  of the spare goes above the far seat and three tenths below your own
  badge.

The rail shows what a phone has no room for: **what has gone**. That is
the 52 cards with the played ones struck through, plus a line counting
hearts played and saying whether the queen is still out. Everything on
it was played face up, so it is a memory aid and gives nothing away.

## Motion

Movement shows where a card came from and where it went. Every card that
changes hands travels the way the table is laid out
(`seatDirection`, `app/lib/ui/table_view.dart`):

- **A card played** rises from the hand and lands in its slot from its
  player's side. It comes in fast and settles, coming down onto the felt
  slightly large and askew. A card dragged and released carries on from
  the finger.
- **Passed cards** leave toward the receiver's side, and received cards
  arrive from the passer's.
- **A finished trick** gathers onto the winning card and goes to its
  taker.
- **The hand closes** over a gap and opens for an arrival.

Arrivals decelerate, departures accelerate, and moves within the screen
ease both in and out (Flutter's `Easing`). A play takes 240 ms, a pass
420 ms, a trick sweep 300 ms and the fan settle 220 ms. Animations that
are triggered by a tap begin one frame in, so the first drawn frame is
never a frame of nothing. With `MediaQuery.disableAnimations` the table
is identical, just with nothing in flight.

At the end of a hand the last trick is named and swept, there is a beat
of bare felt, and then the score sheet comes down. At a live table the
next hand is already being dealt underneath. The beat is a step of the
screen's walk through the record, not a separate timer, so incoming
events cannot cut it short.

The heart on the front door folds and opens over nine seconds, then
holds still until twenty seconds have passed. It requests no frames
between turns.

## Profile pictures

A badge is 64 pixels across, and people are rarely in the middle of
their own photos. So the crop is chosen by hand: drag to move, pinch to
zoom, and what is inside the circle is what gets kept. The photo is
requested at 1,000 pixels so a tight crop still has detail. The crop
arithmetic is `Window` in `app/lib/ui/photo_crop.dart`, tested on its own
in `app/test/photo_crop_test.dart`.

## Colour

**Gold means something you can do**: a button, a playable card, the seat
whose turn it is. Nothing else is gold, so gold keeps its meaning.
Information is white: scores, ratings, your row, the trick just taken, and
the ring around your chosen icon. **Red belongs to the game**: hearts,
points against you, a loss. Each screen has at most one filled gold
action. `app/test/palette_test.dart` checks this.

## Text size

The table follows the reader's text size up to twice the ordinary
(WCAG 1.4.4), at every shape above and in every language.
`app/test/table_fits_test.dart` plays a game alone and a live one
through every phase at text ×1, ×1.3, ×1.5 and ×2. It fails on any
overflow, any line cut short, and anything drawn over anything else.

- **Words keep the size the reader asked for.** The header, the action
  line, the line under your badge and the score sheets wrap rather
  than shrink. The header takes a second line, and where two cannot
  hold it, it drops the score the game is played to, which never
  changes. The action line is as tall as two lines of its prompt beside
  the Pass button. Where two lines cannot hold the prompt, it says only
  how many cards are left to choose, since the button says "Pass". The
  sheets' numbers are never broken. Where a name will not fit beside
  them, every row puts its numbers under its name.
- **A name gives way first.** A long name is cut short with an ellipsis
  before the sentence around it, or the cards beside it, are.
- **Pictures stay pictures.** A card's rank and suit are drawn at the
  card's size, and so are the initials in a player's icon. A fan shows
  only a sliver of each card, so a bigger rank would hide under the
  next card. The cards grow with the felt instead, and a screen reader
  says each card's name.
- **The felt gives way last.** Badges, and the line beside your badge on
  a wide felt, scale into the room the felt has. Where even the smallest
  trick will not fit, which happens at ×2 on a phone on its side, the
  whole felt is drawn slightly smaller rather than run off the screen.

## Screen readers

The table can be played entirely through the accessibility tree. Each
card is a named node, and unplayable cards are disabled. Each seat
announces its score and where it sits ("on your left"). Trick winners
and "Your turn" are announced as they happen (`Announced`,
`app/lib/ui/table_view.dart`). Each score row reads as one sentence.
`app/test/accessibility_test.dart` checks that every tappable node on
the front door has a name.

On the web, Flutter builds the tree only after the hidden "Enable
accessibility" button is pressed. This is Flutter's default and spares
other visitors the cost. The e2e suites pass `?e2e=1`, which builds the
tree from the start. Known gaps: a card chosen to pass is announced as
"current" rather than "selected". Cards on the felt are read in the
order they are drawn. The led card is marked "led", and play order
follows the seats round from it.
