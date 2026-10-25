# Roadmap

What we plan to build, and what we have chosen to wait on and why. It
is a plan, not a promise. What has shipped is in the
[changelog](CHANGELOG.md). To suggest something, open an issue.

## Planned

### Getting found

- **Search.** openhearts.game already has a title, a description, link
  previews and a page per language. Still to do: a sitemap, and the
  site verified in Google Search Console so that it is indexed.
- **Pages people search for:** how to play, the rules in full, shooting
  the moon, and strategy. Today the rules are eight lines among the
  support page's questions.
- **The store listings:** screenshots (the first three matter most), a
  preview video, keywords, and a description that leads with no ads,
  free play alone, deals anyone can check, and the Auto switch. In each
  of the app's languages. What the stores ask about how the app works
  is answered in [what the stores are told](docs/reference/store-answers.md).
- **Asking for a review** after a good moment, such as a win, through
  the stores' own prompt.
- **More languages,** where Hearts is played: Dutch first.

### Learning and playing

- **A tutorial** for new players.
- **Themes:** light, dark, classic green, and one for colour blindness,
  with a switch for larger cards and text. Today there is the green
  felt, and the app follows the device's text size.
- **Bot speed** when playing alone: slow, normal or fast. Today the
  bots keep one pace, and the Auto switch plays out a hand that is
  already decided.
- **A wait after quitting.** A player who leaves a live game early
  can't start another one straight away.

### Your record

- **More statistics** on the profile: losses, win streaks, games
  finished, how often you finish in each place, the points you take in
  a hand, your rating over time, and the queen and the moon in live
  games too. Today the profile has the rating; games played and won,
  the average and the best, live and alone; and, alone, the recent
  scores, the queens taken and the moons shot and blocked.
- **Badges** for achievements, shown on profiles. Each player chooses
  which of theirs to show.
- **A card to share a finished game:** the score and its highlights,
  linked to the game's turn-by-turn record and the check of its deal.
  Nothing is shared while the game is on.

### Playing with friends

- **Links that open the app** where it is installed, and the web where
  it is not. Today a link to a room always opens the web.
- **A notification for an invitation** to a friend's table, and for
  nothing else.
- **Clubs:** private groups that last, with their own leaderboard and
  tables quick to start, and voice and video chat for games among
  friends only. Video needs care on a phone's screen.
- **Family Sharing** for the subscription on iOS. The service would
  take a family-shared purchase as a licence for each family member's
  own account. Apple doesn't let Family Sharing be turned off once it
  is on, so it is turned on only once that works.

### Knowing how it's used

The service and the relay already count what they do, in Workers
Analytics Engine ([Watching it run](docs/explanation/service.md#watching-it-run)):
each request to the service by handler, status and time taken, and each
relay object's connections, events, deliveries and refusals. Today
they are read only by asking the Analytics Engine SQL API.

- **A dashboard** would show them over time in one place, beside New
  Relic's checks of whether the site, the app and the relay are up, so
  that a slow handler, a rise in refusals or a quiet day is seen
  without asking. Like the counts themselves, it would show nothing
  about anybody.
- **Product analytics, kept in house,** with no third-party vendor and
  an anonymous random ID per device. The first events: the app opened;
  a game started, finished or abandoned; each step of the tutorial; the
  way to subscribing; an invitation sent and accepted; and the wait for
  a table. From them: how many come back after a day, a week and a
  month, and games per player per week. This is new: today nothing is
  counted about anybody, so the privacy policy and the App Store's
  privacy label change before any of it is collected.

### Research

- **What other Hearts games do:** a map of the features of the ten most
  active, and the gaps between them. Among them Hearts+, Trickster,
  Optime Hearts, Hearts Deluxe, Hearts Card Game Classic, hyilmaz
  Hearts, MobilityWare Hearts and Hearts Expert AI.
- **How many people play Hearts,** and could play it here. How to
  measure it isn't decided.

## Waiting on more players

### Rule options

Long-time Hearts players expect some options the game doesn't have yet:

- the Jack of Diamonds counting −10 for whoever takes it;
- choices in how shooting the moon scores;
- a game to 150 points, beside the 50 and 100 there are now;
- other ways of passing, such as passing in no hand at all, not only
  every fourth.

Each is small to build. But everyone at a live table plays by the same
rules, so each option splits the players waiting into more pools, as the
100-point game already does (`poolTag` in
`packages/table/lib/src/matching.dart`). Fewer players in each pool
means longer waits for a table. So these options wait until the
standard pool has enough players to spare.

### Leaderboards

All time, and by the day, the week and the month. A board with a
handful of players on it says little, so the boards stay hidden until
enough people play. A board is a view of the ratings, and ratings are
never reset.

### After a game with strangers

Two ways on from the end of a game at a table found at random: **Play
again** with the same people, if they choose it too, and **Mix it up**,
which avoids them unless they are the only ones online. Today Play
again finds a new table the way the last one was found. Mix it up is
shown only when enough people are online for it to mean anything.

## Later

### Game Center and Google Play Games

Badges as achievements in Apple's Game Center and Google Play Games,
and the game found through Apple's Games app. It waits for the badges.

## Decided against

We have thought about these, and aren't building them:

- **Bot difficulty levels.** Bots are rated like players, and a table
  takes bots rated near its players, so the matching already gives each
  player bots of their level.
- **Hints, and taking a card back.**
- **Daily challenges.**
- **Three to six players, and teams.**
- **Giving a subscription as a gift.**
- **Resetting a rating.**
- **Coming back to a seat once a bot has taken it over.** Coming back
  to a seat that is still yours, after a reload or a dropped line,
  works today.
