# Screens

This page explains how the app lays itself out on every screen, and the
design rules behind it. The sizes and timings it describes are constants
in the files it names.

The web build and the app builds are the same product. The layout
depends on the space the table is given, never on the device. There are
no platform checks, no device lists and no user-agent sniffing. A phone
turning sideways, a foldable opening, Split View and a desktop window
being resized are all the same event: new constraints.

The app is checked at the shapes people play on: a phone upright and on
its side, a tablet, a foldable closed and open, and a desktop window of
any size, resized mid-game. The shapes themselves are listed in
`app/test/fits.dart`, and `e2e/shots.mjs` screenshots the built app at
each. Rotating, unfolding or resizing mid-hand never costs the game:
`app/test/tablet_test.dart` and the widget tests for the phone on its
side check this.

## Portrait and landscape

`app/lib/ui/table_layout.dart` treats the table as landscape only when
it is clearly wider than it is tall (`isLandscape`). A near-square window
is laid out as portrait, where the fan of cards needs the width. The two
compositions share every widget. Both have the same header: the menu on
the left, the hand number and pass direction in the middle, and on the
right a heart that stays whole until hearts are broken. They differ in
the hand row: in landscape it is shorter, and the fan steps further
between cards (`app/lib/ui/hand_fan.dart`), so the shorter cards show
more of themselves. On a wide felt the trick lies flatter and the seat
badges fit on one line.

All four seats, yours included, have a badge on the felt. Each badge is
the same gap from the card it labels, on all four sides, so it reads as
that card's label. A badge shows the player's total and what they have
taken this hand. Each badge hugs its name, and the two badges of a pair
are laid out to the same size, so a long name and a short one match. The
trick is sized from the height the badges leave, so nothing overflows
when a name wraps or the text size goes up. A bot's icon wears a small
robot at its lower right, over the icon's edge only a little, so the
face or picture stays whole (`BotMark`, `app/lib/ui/player_icon.dart`).
Touched, it says "Bot". The felt and the score sheets draw a seat's
icon the one way (`SeatIcon`, from the table's `SeatLook` of the seat),
so the mark is on both, alone and at a live table.

What the table says (who took the trick, whose turn it is) floats under
your badge. The action line (what you were passed, how many cards are
left to choose, the Pass button) sits against the hand, as wide as the
fan. Its row is always as tall as its tallest state, so the table above
never shifts.

## The hand that teaches

A device that has played nothing alone is offered a first hand of
Hearts, taught, under Play solo; the menu has it for anyone
(`app/lib/tutorial.dart`). It is a game alone against three bots, dealt
the same way every time, with a note at each thing the hand brings a
new player to for the first time. A note that tells something holds the
table, the bots and your own cards with it, until you tap Next; a note
that asks for something (the pass, the 2 of clubs, a card of the suit
led) stays until you have done it. The notes say what the rules allow
and what follows from them, never which card to play.

The note is never drawn over the table. It takes room of its own, and
the felt gives way to it (`note`, `app/lib/ui/table_layout.dart`):

- **Upright, under the felt,** just above the action line and as wide
  as it. It takes what it needs, up to four tenths of the table's
  height.
- **On its side, beside the felt,** at the right, where the thumb is:
  at most 360 points at a phone's scale, or half the width. A felt on
  its side is short of height, not width.
- **The felt keeps its arrangement.** It chooses wide or upright from
  the room it has before the note takes any (`FeltRoom`,
  `app/lib/ui/table_view.dart`), so a note coming and going changes
  how big the table is drawn, never how it is laid out. The felt keeps
  its place in the widget tree either way, so nothing on it starts
  over when a note comes.
- **At ordinary type every note fits** on every screen in the matrix.
  At larger type, a note longer than its room scrolls, with Next still
  under it.

The note is drawn at the table's scale, like the action line, and a
screen reader says each note as it comes. `app/test/tutorial_fits_test.dart`
plays the taught hand through every note at every shape, text size and
language of the matrix, and on a narrow phone on its side.

## Tablets

A phone layout scaled up is the wrong answer: enormous cards and a fan
you have to reach across the device to touch.

- **The table holds a width.** Past its width (`tableWidth`), the table
  stops spreading. Leftover width becomes a rail beside it once there is
  enough for one (`railLeast`), and the rail stops growing at a most
  (`railMost`); any width past that is margin. The table and its rail
  are centred together.
- **The cards grow with the felt,** as a share of the felt's shortest
  side, from a phone's size up to a most (`app/lib/ui/scaled.dart`).
- **The type grows with the cards.** The table has one scale, from 1 on
  a phone up to the cards' most over their least. Badges, the table's
  line, the action line and the rail are all drawn at that scale. The
  header stays the same size everywhere.
- **The table sits low.** On a felt with height to spare, most of the
  spare goes above the far seat and the rest below your own badge.

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
ease both in and out (Flutter's `Easing`). Each movement is a fraction
of a second, a pass a little longer than a play; a card's landing and a
trick's sweep are `Pacing.cardLands` and `Pacing.trickSweeps`
(`app/lib/pacing.dart`), and the rest are in `app/lib/ui/hand_fan.dart`
and `app/lib/ui/table_view.dart`. Animations
that a tap triggers begin one frame in, so the first drawn frame is never
a frame of nothing. With `MediaQuery.disableAnimations` the table is
identical, just with nothing in flight.

At the end of a hand the last trick is named and swept, there is a beat
of bare felt, and then the score sheet comes down. At a live table the
next hand is already being dealt underneath. The beat is a step of the
screen's walk through the record, not a separate timer, so incoming
events cannot cut it short. Alone, with the Auto switch on, nobody waits
on anybody: each card comes as the one before it lands, a trick goes as
its last card lands, and the sheet follows the sweep. After a moon the
beat is kept, switch or not, for the quake below.

A trick with points in it lights up the badge of whoever wins it, from
the moment it is won: pink, the colour of points taken, and red, the
game's own, when the queen is in it (`app/lib/ui/table_view.dart`). The
glow holds while the trick is on the felt and swept to the winner, and
fades once the cards are in, the queen's half a second later. It takes
the place of the white border the winner of a trick without points
wears, so a trick is told once. The glow is drawn round the badge and
never across it, so what the badge says reads as always. A trick the
table never showed, because the screen caught up past it, lights
nothing.

Shooting the moon is taking every heart and the queen in one hand: all
26 points, which the rule turns round, so that everyone else takes 26
and the shooter none. Whoever shoots it, the felt quakes as the last
trick reaches them. The table jolts away from the shooter's badge and
settles, and rings run out from that badge under everything on the
felt. It is over within the beat of bare felt (`Pacing.moonQuake`
within `Pacing.sweepBeat`), so the sheet comes down on a still table,
and a moon already over when the screen opens does not quake again.

A game the player won rains confetti in red, white and pink as its
sheet comes in, once, for under three seconds
(`app/lib/ui/confetti.dart`). Some of it falls behind the sheet and
some in front of it, so it falls through the table rather than on a
pane over it. A game shared at the top counts as won.

None of these can be touched or heard: taps go through them, and screen
readers never meet them. With `MediaQuery.disableAnimations` there is no
quake and no confetti, and a glow fades from the moment its trick is
taken, as nothing is swept.

The heart on the front door folds and opens, then holds still for a
while (`app/lib/ui/folding_heart.dart`). It requests no frames between
turns.

## Profile pictures

A badge is small, and people are rarely in the middle of their own
photos. So the crop is chosen by hand: drag to move, pinch to zoom, and
what is inside the circle is what gets kept. The photo is requested
large enough that a tight crop still has detail
(`app/lib/profile_page.dart`). The crop arithmetic is `Window` in
`app/lib/ui/photo_crop.dart`, tested on its own in
`app/test/photo_crop_test.dart`.

## Colour

**Gold means something you can do**: a button, a playable card, the seat
whose turn it is. Nothing else is gold, so gold keeps its meaning.
Information is white: scores, ratings, your row, the trick just taken, and
the ring around your chosen icon. **Red belongs to the game**: hearts,
points against you, a loss. Each screen has at most one filled gold
action. `app/test/palette_test.dart` checks this.

## Text size

The table follows the reader's text size up to twice the ordinary
(WCAG 1.4.4), at every shape above and in every language. The
`table_fits` tests play through every phase at every text size the
matrix in `app/test/fits.dart` lists: a game alone
(`app/test/table_fits_test.dart`), a live one
(`app/test/table_fits_live_test.dart` and
`app/test/table_fits_live_end_test.dart`) and a wide felt
(`app/test/table_fits_wide_test.dart`). They fail on any overflow, any
line cut short, and anything drawn over anything else.

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
  trick will not fit, which happens at twice the text size on a phone on
  its side, the whole felt is drawn slightly smaller rather than run off
  the screen.

## Screen readers

The table can be played entirely through the accessibility tree. Each
card is a named node, and unplayable cards are disabled. Each seat
announces its score and where it sits ("on your left"), and whether it
is a bot. Trick winners
and "Your turn" are announced as they happen (`Announced`,
`app/lib/ui/table_view.dart`). Each score row reads as one sentence.
`app/test/accessibility_test.dart` checks that every tappable node on
the front door has a name.

On the web, Flutter builds the tree only after the hidden "Enable
accessibility" button is pressed. This is Flutter's default and spares
other visitors the cost. The browser suites pass `?e2e=1`, which builds
the tree from the start.

Known gaps: a card chosen to pass is announced as "current" rather than
"selected", and cards on the felt are read in the order they are drawn.
The led card is marked "led", and play order follows the seats round
from it.
