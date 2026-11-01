# Changelog

Notable changes to Open Hearts. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Open Hearts has
no numbered releases yet: every deploy of `main` is the current version,
so each entry gives the date it landed and its commit or, for a change
squashed from a pull request, the pull request's number.

## [Unreleased]

### Added

- Four pages for people who search for the game: how to play Hearts,
  the rules in full (with the variants this game leaves out), shooting
  the moon, and strategy, at `/how-to-play`, `/rules`,
  `/shooting-the-moon` and `/strategy`, in all five languages, and in
  the sitemap. The front page has them under "New to Hearts?", every
  page's footer links How to play and Rules, and each of the four links
  the others and ends with Play now. The support page's answer to "How
  do I play?" links How to play, and its rules in brief link the rules
  in full. (2026-10-26, #40)

- A wait after leaving a live game early. A device that leaves a game
  Play live seated it at, while somebody else is still playing it,
  waits five minutes before Play live seats it again; the front door
  says until when, and playing alone and with friends stay open. A seat
  the table gives to a bot, its clock run out or the device gone quiet,
  counts the same, and so does the app closed mid-game for longer than
  a table waits. Leaving a friends' room, a game with only bots left in
  it, or a game that failed for everyone does not. The wait is kept on
  the device and nowhere else, and the operator can change it, or set
  it to none, with the remote config's `leftEarlyMin`. The support page
  has a new answer, "What if I leave a live game early?". (2026-10-26,
  #40)

- On the phones, a moment after you win a game, the app asks the App
  Store or Google Play for its own prompt to rate the app, at most once
  every four months. Whether the prompt shows is the store's to decide,
  and the app is not told what you chose there. The web asks nothing.
  (2026-10-25, #39)

- A first hand of Hearts, taught. A device that has played nothing
  alone is offered it under Play solo ("New to Hearts? Learn to
  play"), and the menu has it for anyone. It is a game alone against
  three bots, dealt the same way every time, with a note at each thing
  the hand brings a new player to for the first time: the pass, the
  cards that came, the 2 of clubs, following suit, a suit you have none
  of, a trick taken, hearts broken, the queen of spades, and at the end
  how a hand is scored. A note that tells something holds the table
  until Next; one that asks for something waits until it is done. The
  notes never suggest a card. Each takes room of its own, under the
  felt or beside it, and covers nothing on the table. In all five
  languages. (2026-10-25, #39)

- `openhearts.game/sitemap.xml` lists every page of the site in each of
  its languages, by the address the page gives as its own, with its
  copies in the other languages; the site's `robots.txt` names it.
  (2026-10-25, #39)

- The App Store and Google Play listings, in all five languages. Their
  words are `site/store.json`, held to each store's limits and rules by
  `site/store.test.mjs`. Their pictures are made from the app by
  `e2e/store_shots.mjs`: five screenshots at each size the stores ask
  for, those of games played alone the same in every language, and
  Google Play's feature graphic and icon. `docs/how-to/update-the-store-listings.md` says
  where each goes. (2026-10-25, #39)

- Previews play live. They have a relay of their own (`open-hearts-relay-preview`,
  at `relay-preview.openhearts.game`), with its own households and backup
  jurors on the previews' store, and a service key pair of their own.
  Nothing a preview signs is good in production, and it takes nothing
  production signed. Nobody buys anything on a preview: `oh preview invite`
  makes an account that plays there for a year and prints one of its
  backup codes, which a device enters under Activate subscription. `oh
  preview secrets` makes the previews' secrets without showing them, and
  `oh deploy relay --preview` deploys the preview relay from any branch.
  A preview emails nobody, and its tables carry no profile pictures,
  since only production checks them. (2026-10-24, #38)

- At a live table, a bot's juror plays its card as soon as it hears the
  bot card before it, rather than waiting for the person's device to
  have seen that one: the bots between two of a person's cards take one
  round trip of the person's line, not one each. With the line 300 ms
  each way, the wait from a person's card to their next turn fell from
  1.3–1.9 seconds to 0.7–0.9. (2026-10-24, #38)

- A bot's icon wears a small robot at its lower right, over the icon's
  edge only a little; touched, it says "Bot". On the felt and on the
  score sheets, alone and at a live table. A screen reader says "a bot"
  after the seat's name. (2026-10-24, #38)
- `oh table <id>`: what the backup jurors, the relay and the player's
  device each said of one live table, in one timeline. The relay now
  logs each socket's coming and going, and the backup jurors' object
  what it did with them, by the table's first eight characters and
  nothing about anybody; a device on the web tells New Relic of a game
  it lost, or a line down for two minutes, with what it saw.
  (2026-10-24, #37)
- On a phone, live play, and buying it in the store, ask the App Store
  or Google Play first whether the player may play live: closed, with
  a note saying why and that playing alone is open, for a player the
  store says is under 13, a supervised player whose parent has not
  approved the app's latest changes in Google Play, or one Google Play
  needs to confirm their age. The answer is not kept or sent; the
  privacy policy says so. (2026-10-23, #37)
- A game the player won rains confetti in red, white and pink as its
  sheet comes in, some of it behind the sheet and some in front: once,
  and not where the device asks for less motion. (2026-10-23, #37)
- A moon, whoever shoots it, quakes the felt as the last trick reaches
  the shooter: the table jolts away from their badge and settles, and
  rings run out from it. It is over before the sheet comes down, and
  there is none where the device asks for less motion. (2026-10-23,
  #37)
- A trick with points in it lights the taker's badge as it reaches
  them: pink, and red half a second longer for the queen. (2026-10-23,
  #37)
- `robots.txt`, on openhearts.game and play.openhearts.game, names
  Project Arachnid's crawler, which Arachnid Shield checks before it
  takes Open Hearts on. Every other crawler is let in, as before.
  (2026-10-23, #36)
- A player deletes their account in the app: **Delete account**, at the
  foot of the subscription page, on any device in the account, lapsed or
  suspended too. It asks first, and says that the time left on the
  subscription is lost and that cancelling is the way to stop paying
  without that. The service ends a web subscription in Stripe, takes the
  account's name off its kept games, deletes its rows and cuts its device
  in use off at the relay; the device forgets everything it keeps and
  starts again as a new player. A kept game notes the accounts at its
  seats, so only that account's games are read. The support page says
  how, for Google Play, and the terms and privacy policy say so, in every
  language. (2026-10-19, #32)
- The first time a device goes to play live, it asks the player to agree
  to the terms, saying that the others will see their name and picture.
  (2026-10-19, #32)
- A player can block another from the table: on that device, the other
  is shown by no name, no picture and no reactions, at the table, in a
  room, watching and reviewing a game. Nobody is told. (2026-10-19, #32)
- A player can report another from the table, for their picture, their
  name or something else, with a note. The operator is emailed at once,
  with both accounts, what the reporter saw and the commands to act on
  it; a subscriber can send ten a day, the same report once a day.
  (2026-10-19, #32)
- A picture is the account's: the account's turn checks it as the
  account sets it, before anyone is shown it, and keeps the account's
  own copy of it, apart, for the operator, until a year after it stops
  being the account's (replaced, taken off, or the account deleted), as
  long as a hold keeps one reported. Everything known of a picture
  travels with that one copy, and two accounts that set the same picture
  have one each, each checked and acted on for itself. The account's
  picture now is the one it set last, and the relay carries only that
  one. A room or a pool waits for a profile
  save on its way, so a picture just changed goes once the service has
  it. (2026-10-19, #32)
- Pictures are checked as an account sets them, by Cloudflare's Workers
  AI, for nudity, gore and hate symbols. One the check flags is withheld
  from everyone within a couple of minutes, and the daily email shows it
  first; `./oh picture allow` puts one back. (2026-10-19, #32)
- Each new picture is checked by Microsoft's PhotoDNA against known
  images of child sexual abuse as an account sets it, asked from one
  object kept in the United States. A match is never shown or kept: the
  profile is saved without it, each account that set it is held and
  terminated, its web subscription ended with nothing refunded, the
  match is reported to NCMEC's CyberTipline, and the operator is emailed
  what was done, all without waiting on the operator. Each step is tried
  again until it is done, and any failure emails the operator. Off until
  PhotoDNA's key is set; reports are filed once NCMEC's credentials are,
  and until then the email says to file one by hand. (2026-10-19, #32)
- Known images of child sexual abuse are found by the Canadian Centre
  for Child Protection's Arachnid Shield instead of Microsoft's
  PhotoDNA, and Shield is never sent a picture: the relay decodes it,
  makes its PDQ hash with a port of Meta's reference that makes the same
  hash bit for bit, and asks Shield about the hash. A picture Shield
  knows as harmful or abusive material of a child, not child sexual
  abuse material, is refused and withheld, and the operator emailed with
  the command to suspend the account; nothing else is done by itself.
  A match with Shield's test pictures is logged and acted on for nobody,
  a picture too featureless to match is not asked about, and one that
  can't be decoded is refused as a match is. The privacy policy names
  the Canadian Centre for Child Protection. (2026-10-22, #34)
- Microsoft's PhotoDNA can stand in for Arachnid Shield as the checker
  of known images, with one command and no deploy: `./oh config set
  known`, the run-time row `config|known`. Shield stays in use unless
  the row names PhotoDNA. PhotoDNA is sent only a picture's PhotoDNA
  Edge Hashes, made with the module Microsoft licenses to Open Hearts,
  which is kept in a new private bucket, pinned in
  `config/openhearts.json`, and fetched only to deploy the relay (`oh
  photodna put`, `oh photodna get`); `check.sh` fails on anything of it
  committed. What either checker said of a picture stands whichever is
  in use, so a switch asks about nothing again. The privacy policy says
  that PhotoDNA may stand in for Project Arachnid, in every language.
  (2026-10-23, #37)
- Each account's copy of a picture keeps the receipt for what was said
  of it against known images, which checker said it and when, and so
  does each match's case. The daily email of new pictures says it of
  each picture, or that a picture isn't checked yet. (2026-10-23, #37)
- The terms or the privacy policy can change twice in a day: a ledger
  entry dated the day of the one before is that day's next revision,
  named `2026-10-23.2` by `oh terms` and in the record of who was told.
  Subscribers are told of it as a change of its own, and the app shows
  it again where the day's first was dismissed. (2026-10-23, #37)
- Every new picture is emailed to the operator once a day, account by
  account, with the commands to take it down. The daily run does only
  what each copy says is still to do: it keeps what is kept for as long
  as the privacy policy says whether or not the email is on, asks
  PhotoDNA again about any picture it has not cleared, and emails the
  operator if it fails. (2026-10-19, #32)
- Names that are obscene or slurs, in five languages, are refused by the
  app, the service and the relay, matched as whole words so real names
  stay. (2026-10-19, #32)
- A legal hold keeps an account's data for a year at the least after a
  report the law requires, with a copy of each picture the account set
  in its last year, kept where only the operator reaches it.
  `docs/how-to/handle-abuse-material.md` is the procedure for child
  sexual abuse material that PhotoDNA doesn't catch. `./oh picture
  report` has the relay handle a picture the operator found as it does a
  match, with a report saying the operator looked at it. For what is
  done by hand, `./oh account find` takes a picture's SHA-256 or address
  to the accounts that set it, and `./oh picture hide` withholds one an
  account no longer uses. (2026-10-19, #32)
- `./oh`, one command for every operator task, each saying what it would
  do and changing nothing without `--apply`; `docs/reference/oh.md` is
  made from it. (2026-10-19, #32)
- Every published version of the terms and the privacy policy is an
  entry in `site/ledger.json`, which CI and a production deploy hold the
  text to. Devices show a material change at the front door, and
  `./oh terms notify` emails web subscribers. (2026-10-19, #32)

- A picture the operator takes off an account is withheld at the relay
  within a couple of minutes, for 30 days or until it is put back. No
  pool or room serves it again, even if a device of the account puts it
  out again. Before, it stayed for a day wherever it had been put out.
  (2026-10-16, #31)
- The operator can suspend an account from live play and lift it, and
  take its name or picture off and put them back, as the terms allow,
  with `service/tool/suspend.mjs`. A suspended account's device in use
  is cut off at the relay at once and leaves its table, its devices get
  no licence, and where the app would sell live play it says the account
  is suspended and where to ask why. A device brought into the account
  later is suspended too, and a subscription one of its devices buys
  stays with it. A name or picture taken off leaves the device in use
  within 20 minutes, and a name leaves the account's kept games too. Both
  tools' `--find` also finds an account by a name taken off. The privacy
  policy says what is kept meanwhile, in every language. (2026-10-13, #29)
- On the web, Stripe's checkout will not take payment until the buyer
  ticks that they agree to the terms and to the yearly renewal, in the
  app's language. The email that follows each purchase says what was
  bought, how it renews and how to cancel, with the backup codes. Before,
  only an account's first purchase was emailed. (2026-10-13, #28)
- The terms name Bright Fulton, who runs Open Hearts as a sole
  proprietor, as the party to them; set an age for live play (13, and a
  parent's or guardian's agreement to subscribe under 18); say what a
  device does as a juror; give the licence a player grants for the
  name, picture and games they publish; let us suspend a device or
  account that breaks the table's rules; and say how to send a
  copyright notice or counter-notice, and to whom. (2026-10-13, #28)
- `infra/apply.mjs` checks the Pages secret for Google Play's service
  account whenever `config/openhearts.json` names Play.
  (2026-10-11, #12)
- At an empty pool, a player may choose to wait for a person instead of
  playing bots, and the operator is told someone is waiting.
  (2026-10-11, 45cc3a3)
- Workers Analytics Engine counters on the Pages worker and the relay,
  turned on through `infra/`. (2026-10-11, 2c240da)
- A subscriber's profile (name, icon, colour, picture) is the account's,
  and every device of the account shows the same. Before, a profile was
  kept only on the device. (2026-10-07, de1d8c4)
- Sign in with Apple's server-to-server notifications, at
  `/api/apple-id`. Both `account-delete` (Apple's earlier spelling) and
  `account-deleted` are accepted. (2026-10-07, eed3365)

### Changed

- The code is simpler throughout, after an engineering audit of every
  part of the repository: copies of the same logic made one, each
  service call and Stripe call made one way, error strings the app
  matches kept in one table, misleading names renamed, and comments
  rewritten in plain words where they were wrong or hard to follow.
  Nothing a player sees changes. (2026-11-01, #47)
- A production deploy of the site deletes old deployments before it
  publishes, as `./oh deploy prune --apply` does, so nobody has to
  remember to. It keeps the newest five previews, the newest three
  production deployments, as many again of each that succeeded (so
  failed uploads never leave nothing to roll back to), and every live
  deployment: production's on its domains, and the newest of each
  preview branch on its branch's address. The old sweep counted those
  last among the previews to delete, which Cloudflare refuses unless
  forced. Running before publishing keeps the deployment being
  replaced, since it is still live then. A listing it cannot read
  deletes nothing. If the cleanup fails, the deploy says so and goes
  on; a preview's deploy deletes nothing. The cleanup is `oh`'s now:
  `deploy.sh` no longer takes `--prune`, and needs no Python. `oh`
  refuses an empty flag value (`--label ''`), which is most likely an
  unset variable. (2026-11-01, #47)
- Bots never take longer over a card than the quickest person at the
  table. A person's pace is the middle of the times they took over their
  last three cards; at a live table the house keeps each bot's thinking
  to the quickest pace there by the log's clock, and at a solo table
  the bots keep up with their player, though never quicker than a card
  can land or the trick before it be swept. Someone who plays fast, or
  turns on Auto, has the bots keep up within a card or two; someone who
  takes their time slows nobody. (2026-10-31, #44)
- A live table is refereed. Each table's object on our relay keeps its
  log: every event its people and the house send, in one order and
  stamped with one clock, and when each seat's connection to it closed
  and opened again. Every device applies the same rules to the same
  log, so all of them come to the same table, and nothing is voted on.
  The house, the operator's server, plays every bot's seat, holds half
  of each person's escrow, and says how each game came out; ratings are
  worked out from the results it signs, which name the log as it
  ended, and the relay takes results from the house alone. A live game
  goes through the relay only, no longer device to device, and a
  device no longer serves as a juror at anybody else's table. A kept
  game is the referee's log, checked by the same rules; games kept
  before read and check as they did. The house serves only a table
  whose every person holds a licence for their key, and a kept game
  without them is refused. An event is known by the hash of its text
  with every object's keys in order at every depth, which the relay and
  the devices work out alike. A device that has heard nothing on its
  line for five seconds asks for the log again, so that a stalled
  connection is found out while it waits on others. Every word players
  and subscribers read about live tables says so, in all five
  languages, the privacy policy and the terms among them.
  (2026-10-31, #42)
- Leaving a live game while it is on asks first, from the menu or by
  Back, a phone's or a browser's, and says what leaving costs: the
  seat, a rated game counted as last, and Play live's wait where there
  would be one. (2026-10-26, #40)
- A live table gives a bot the seat of a person whose connection to it
  has been closed for half a minute, at their turn, not two minutes. A
  person who is there and slow is still timed by their clock.
  (2026-10-26, #40)
- The front door's top corner has your rating, the number alone, just
  left of your picture, from your first rated game; the sentence under
  the game options that said it is gone. A screen reader hears it as
  "rated", then the profile button as before. How many other people
  are online follows the game line once it is known, "50 points ·
  rated · 3 online", and is 0 when nobody else is; nothing is said
  while it is on its way. (2026-10-24, #38)
- A picture of your own is cut down to 192 by 192 pixels, not 64 by 64:
  sharp at the size the profile page shows it on a phone, where a
  64-pixel picture was blurred to three times over. A photograph that
  size is still a JPEG under 12,000 bytes, so nothing the relay or the
  service carries grows past what they take. The image check's line of
  0.5 was tried again at the new size and holds; PhotoDNA matches
  Microsoft's test pictures at it as at 64; the privacy policy says the
  new size, in every language, as a minor change. Pictures already set
  stay as they are until set again. (2026-10-24, #38)
- Names that would pass for Open Hearts itself or for the people who
  run it are refused, as a name on the word lists is: the game's own
  name, and admin, moderator, support, staff, official, operator and
  the like, in the app's five languages, matched as whole words so
  that Staffan and Supporter are names like any other. (2026-10-24, #38)
- A trick with points in it is told by one glow, not two: the pink or
  red glow comes up round the winner's badge as the trick is won, in
  place of the white border a trick without points still gives its
  winner, holds while the trick is on the table and swept, and fades
  once the cards are in, as before. (2026-10-24, #38)
- Playing alone, the Auto switch plays the rest of the hand as fast as
  its cards land: the bots stop thinking, a trick goes as soon as its
  last card has landed, and the score sheet follows the last trick's
  sweep, or after a moon, its quake. Turned on while a bot thinks, the
  bot plays at once.
  (2026-10-23, #37)
- `crypto/build_android.sh` links the 64-bit libraries 16 KB-aligned
  with any NDK, and refuses one that isn't, since Google Play takes no
  other. (2026-10-23, #37)
- A change to the terms of use or the privacy policy is one line at the
  front door, "Our terms of use and privacy policy have changed", with
  **What changed** beside it for each document's summary and one tap to
  dismiss them all, in place of a card for each change. A web subscriber
  is sent one email of every change they weren't told of, each
  document's newest, dated the day it was published, in place of an
  email for each; `oh terms notify` shows the email before it sends it.
  Before you first play live, the app asks only that you accept the terms
  of use. (2026-10-22, #35)
- Web subscriptions are sold through Stripe Managed Payments: Link,
  Stripe's merchant of record, sells them worldwide, collects the tax and
  keeps to each country's rules for buying online. A refund of any
  payment, whoever makes it, ends the subscription. (2026-10-19, #32)
- The terms are with Bright Fulton LLC. Disputes go first to 30 days of
  talking it over by email, then to the courts in Charleston, South
  Carolina, individually, with no arbitration. A change applies to a
  subscription from its first renewal at least 30 days after its
  subscriber is told, and no deploy emails anyone. The second legal
  review's other fixes are in, in every language. (2026-10-19, #32)
- The terms name the copyright agent, with their own address, email and
  telephone. If live play ever stops for good, they promise a refund of
  the unused part of a web subscription, and say that the App Store and
  Google Play refund under their own rules; interruptions, outages and
  maintenance earn no refund. They say that signing in
  again brings a new device into an account only for a player who signed
  in with Apple or Google. (2026-10-16, #30)
- The subscribe page says beside the button what the subscription
  costs, that it renews by itself until cancelled and where to cancel,
  and that subscribing is agreeing to the terms. The terms' warranty
  disclaimer names the implied warranties it disclaims, in bold, and
  the privacy policy lists every email a web subscriber gets.
  (2026-10-13, #28)
- A game's record is kept only when each person's seat carries the
  service's licence for its key and no account sits twice, as the app
  checks before it shows one. (2026-10-12, #15)
- A request to delete an account's data forgets the account:
  `service/tool/forget.mjs` finds it by name or email, takes its name off
  the games it played, and deletes its rows. The account is marked, so a
  game kept later is kept without its name. Its results stay on the
  relay under its account number, which nothing the service keeps ties
  to the person any longer; Stripe's payment records of a web
  subscription still hold its email address and its device's key. The
  privacy policy says so in every language.
  (2026-10-12, #13)
- Backup jurors make up a short jury, not only an empty one.
  (2026-10-11, db71b17)
- A game's record is kept only from the device in use of a subscriber
  seated at the table, with signed events of its own in the record, and
  only so many an hour. (2026-10-11, 2483df9)
- The committed wasm is the same bytes from any checkout, and CI checks
  it. `deal.wasm` went from 503 KB to 402 KB and `schnorr.wasm` from
  48 KB to 40 KB. (2026-10-11, 3062911)
- The test suites got faster: the deal's answers are remembered on
  disk, test files run side by side, and long cases moved to a `slow`
  tier. On four cores, every suite run one after another went from
  4,148 s to 1,230 s, and `./check.sh full` took about 750 s.
  (2026-10-08, a401f97, 13c1a1a)
- The deal's proof crates are vendored and ported from arkworks 0.3 to
  0.6, with every byte on the wire and in kept games unchanged. Golden
  vectors written by 0.3, and two games kept by 0.3, hold this.
  (2026-10-08, 3310168, 6ace5b3)
- The app moved from `openhearts.game/play/` to the root of
  `play.openhearts.game`. A browser's device (key, licence, name,
  records, settings) is carried over once through a hidden frame of
  `openhearts.game/carry`, and the old origin keeps its copy for a
  rollback. `openhearts.game/play/` and the site host's `/api/` answer
  404. Links to the old address were not redirected, since none were in
  anyone else's hands; an offline worker installed at the old address
  still opens its last build there when offline. (2026-10-06, e2e3a56)
- Live play is by account: a seat, name, rating and result are an
  account's, and an account plays on one device at a time. Ratings
  started again. Results are published under the `standings` tag, and
  the device-keyed results under the old `results` tag are no longer
  folded. The licence statement is now `oh-licence/2`.
  (2026-10-06, 452ff35)
- Table transitions that each side used to decide for itself are on the
  record: the escrow of a held seat and the draw a deal is sealed to
  (2026-09-28, 92b55c2, 5dfc64a), and the leave and the lost-quorum
  ending (2026-09-29, ef11eaa, a302c94).
- A seat's reveal tokens are proved together under one argument, which
  cut a seat's tokens round from 7,386 to 2,169 bytes. (By 2026-09-26,
  when this history begins.)

### Removed

- Code nothing used: `flutter_webrtc`, which nothing had imported
  since #42; the on-device picture check, which no build had; the
  relay client's one-relay write path, since every write goes to every
  relay; the deal's share-token escrow; and dead members, flags and
  routes across the repository. (2026-11-01, #47)

- Juries, the backup jurors and the duty of every open app to serve
  other tables, the mesh of connections between the devices at a table,
  and the votes and signatures a table settled its seats by: the
  referee's log and the house do all of it. WebRTC and TURN stay, for
  voice and video chat, off the game's path. (2026-10-31, #42)
- The 17 games kept before seats carried licences (4 to 6 October
  2026), whose names nothing but a device's key tied to an account, and
  with them `service/tool/forget.mjs` matching a seat by the account's
  devices. Every game kept since names each person's account by the
  licence at their seat, and the service now refuses one that does not.
  (2026-10-12, #15)
- The path that adopted subscriptions from before accounts, after a
  count showed none in production. (2026-10-11, 0520e34)

### Fixed

- Phone builds carry their commit and the day they were built, so the
  About page shows them and the operator's update notice can reach a
  phone build that is out of date. Before, every store build said
  `dev`. (2026-11-01, #47)
- Live play: a room that refuses this device, or fills without it, now
  closes its connection; a relay's refusal from one room no longer
  shows in the next; Play live and Play friends can no longer be
  entered twice while the name and age checks run; and the cards of a
  game left early count towards the player's pace. A deal that fails on
  this device's own step now says the device can't deal, rather than
  booting the player. (2026-11-01, #47)
- The game options are kept however their sheet is closed; the wait
  after leaving a game early counts down after the clock is set back;
  stepping back for another device also closes what was open over the
  table; Restore purchases on an iPhone waits for what the store found
  before saying there was nothing; a page no longer spins for ever when
  something between the app and the service answers with a page of its
  own; feedback on a phone opens the report instead of only copying it;
  a language chosen in the app is not undone by reloading the site's
  link; and a watched table colours each icon as the table does.
  (2026-11-01, #47)
- `oh verify` fails when infrastructure has problems to fix by hand,
  where it said ok. (2026-11-01, #47)

- Previews play live again. Since the referee, every live table has the
  house at it, and the preview relay had no house of its own: now it
  has, its key the previews' (`./oh preview secrets`), with a new
  service key for the previews beside it. A preview deployed since
  plays live on the preview relay with the people invited to it.
  (2026-10-31, #46)

- The house seats the pools. Until now the waiting devices seated each
  other: the lowest key waiting hosted each round, and the next in line
  stepped in when its seating was late. Two hosts could seat one round,
  parting people seated together. And a device forgot somebody seated
  only once they went quiet, so a player left over could seat
  themselves with people already playing elsewhere: those seats waited
  out their clocks before bots took them, and in a rated pool each
  absent player was rated as having left a game they never saw. Now
  the pool's object on the relay wakes the house while anybody waits
  there; the house seats every round, and takes whoever it seats out of
  the pool at once; a device takes a seating from its house alone; and
  the relay carries a pool's seating from nobody else. The table's
  clocks are the operator's, as the house is told them with every wake,
  and its bots are chosen by the ratings the house folds from the
  results. (2026-10-31, #45)

- A relay deploy no longer leaves the new relay live beside the old
  house. Wrangler uploads the worker before it builds the house's image,
  so when the image's base could not be fetched (the AWS public
  registry's data limit), the new relay ran beside the old container
  and the old site until it was rolled back by hand. `./oh deploy
  relay` now builds everything first with `wrangler deploy --dry-run`,
  which uploads nothing, and if a deploy fails after its upload all the
  same, puts back the version that served before. The house's image is
  built on Docker Hub's official Ubuntu, through Google's mirror of
  Docker Hub. (2026-10-31, #43)
- A browser's own Back at a live table now asks, as the menu does, and
  leaving by it is signed and told to the table at once. Before, the
  page closed without a word, the others waited at the seat's turn
  until the table counted it silent, and the front door never heard
  the table was gone, so the seat was still kept to come back to.
  (2026-10-26, #40)
- A live table no longer says "Your connection is down — reconnecting"
  as it opens. Its line opens a moment after the table does, and until
  then the table took itself for cut off and said so: in a browser on
  the rig, for 0.2 to 1.8 seconds at every table, with the line up all
  along. It says so now of a line that has been up and is cut off, as
  before, or of one that has not opened in ten seconds. (2026-10-25,
  #39)
- A code entered under Activate subscription spent itself, brought the
  device in, and answered "No subscription." whenever the account's
  object ran somewhere other than where the device was: the service
  read the device's licence back from KV at the device's end, where the
  app's own ask of a few seconds before was still held, for up to a
  minute. On preview pr38 every one of eight activations from IAD,
  through accounts whose object ran at ORD, went so. A store purchase
  and signing in on a new device read it back the same way. Each is now
  licensed from what the account's object wrote. For the same minute
  the device was refused nearly everything else it asked. It could not
  take the account up or keep its profile, so Play live said "No relay
  answered". It got no TURN credentials, so its table played without
  data channels. "Wait for a person" told nobody, though it said it
  would. The devices and codes under Manage, a code for another device,
  linking a sign-in, a report, and a game's record were refused too.
  Now the device shows its licence with every request, and a handler
  the store can't answer asks the account the licence names, whose
  object decides. A device dropped from a household keeps its licence
  for up to a month, so what it asks on it is counted apart and spends
  none of the household's hourly allowance. (2026-10-25, #38)
- A live table that stopped for good when the person's connection
  dropped as the bots passed (table 64cf65a3). Back sixteen seconds
  later, their device gave each bot fifteen seconds and took all three
  seats off their jurors at the end of them, a second before the
  jurors' next repeat was due; and with those jurors left out of every
  later draw, the next hand could find no jury to hold its bots, while
  the screen said "Dealing". Now a juror says its card again the moment
  a person's heartbeat shows they lack it, a juror let go is drawn
  again once when nobody else can be, and a table waiting for a jury
  says "Waiting for jury…" in every hand, not only the first.
  (2026-10-24, #38)
- A bot seat given to the escrow while the person's device could not
  reach the jury left the table waiting for good once it could: the
  jurors never heard of it, and went on waiting for the seat's own
  juror. The device now says the claim again until the seat's card is
  played. (2026-10-24, #38)
- On the web, the reactions' emoji are there the first time the picker
  opens, and the first time a reaction shows. They were empty boxes for
  a second or two while the web's engine fetched them from Google's
  font servers; the six now come with the app, cut from the same font,
  and nothing is fetched to draw them. (2026-10-24, #38)
- The count of who is online counts people. The backup jurors, online
  while a table needs them and for ten minutes after, were counted too:
  one player back from a game with bots read "5 online", the four
  backup jurors and themselves. (2026-10-24, #38)
- `oh table` finds the relay's lines and the backup jurors' object's.
  Workers Logs keeps a line of JSON as its fields, with no message, so
  looking for the table in the message found only the jurors' own
  traces. It asks for the relay's lines by their `tag` and the object's
  by their `table` now, and its tests answer as Workers Logs does.
  (2026-10-24, #38)
- Choosing which part of a photograph is your picture, a drag moves the
  photograph with the finger all the way. Before, each step of a drag
  was laid on where the drag began, so the photograph moved by the last
  few pixels and no further, and only pinching did anything. A pinch
  now keeps what is under the fingers under them as they move.
  (2026-10-24, #38)
- A live game no longer ends for a device's own line going down. A
  satellite link on a plane let one player's heartbeats out and nothing
  in: alone at a table of bots, the device took the jurors it could not
  hear for gone, gave a bot seat up for a move it never saw, and ended
  the game as "juror quorum lost" while the jurors played on. Now a
  device that hears nothing back from the relay for ten seconds takes
  itself for cut off, makes its socket afresh, says "Your connection is
  down — reconnecting", and judges nobody silent for the time it could
  not hear. (2026-10-24, #37)
- A jury proposed for the next hand before a side gave its own hand up
  undealt is now backed once it has; the table could wait on it for
  good. (2026-10-24, #37)
- On a phone whose store hasn't said what live play costs, opened
  offline say, the subscription page asks the store again when it opens
  and on Subscribe, shows no price until the store gives its own, and no
  longer says that live play is bought on the web. Before, the store was
  asked once, at launch. (2026-10-23, #37)
- `./oh secret set` sets the relay's optional secrets, Arachnid Shield's,
  PhotoDNA's and NCMEC's credentials, on the relay worker. It refused
  them before, though the abuse-material guide said to use it.
  (2026-10-23, #37)
- A picture Arachnid Shield knew as harmful that the operator then
  reports is acted on as a match for each account that set it: held,
  terminated and reported. Before, each account's harmful case stood in
  the way, and nothing more was done. (2026-10-23, #37)
- A match found because the operator reported the picture before is
  emailed and reported to NCMEC as that, not as Arachnid Shield's.
  (2026-10-23, #37)
- The app's German words in Dart are what `app_de.arb` says. Every
  build rewrote them, which left the checkout changed, and a deploy
  refuses a changed checkout. CI now fails when the words in Dart are
  not what the `.arb` files make. (2026-10-23, #36)
- `oh` tells which version of the terms or the privacy policy the site
  serves by the day its page says it was last updated as well as by its
  text, so an entry that publishes the same text on a later day counts
  as live once it is. Before, the earlier entry did, and every later
  deploy would have refused to go out until the later one was dated
  again. (2026-10-22, #34)
- At a table of two, a player who leaves during the pass or the deal,
  just after backing a move for a seat the jury holds, no longer stops
  the game. Their device now makes the pass the bot would make, or the
  deal step the seat owes, before the leave takes effect. Before, the
  table waited for the other player to boot the seat and a juror to
  rule, and for good if the leaver's device stayed connected.
  (2026-10-13, #26)
- A kept game's record with a decision that names no seat at the table,
  or with a removal carried by anything but a boot, an absence, a leave,
  an escrow or the game's end, now fails its check and says why. Before,
  the check stopped with an error, or at a person's seat took such a
  removal as a boot. And when a check stops with any error, the game's
  page says it could not check the game; in the phone apps it went on
  saying it was checking. (2026-10-12, #23)
- `infra/apply.mjs` took the relay's version metadata binding for one
  not in `service/do/wrangler.toml`, and asked for a fix by hand where
  the worker matched. (2026-10-12, #14)
- Backup jurors still running from an earlier deploy, or with an
  earlier service key, juror secret or relay setting, are started again
  at the next call, so a new image or a rotation reaches them.
  (2026-10-12, #12)
- A relay object's counts are no longer lost when it is evicted inside
  their minute: a timer is kept while counts wait, and the last socket
  closing writes them at once. (2026-10-12, #12)
- For a missing preview secret, `infra/apply.mjs` printed a command that
  set production's instead. (2026-10-11, #12)
- Game results are kept for good again. Since results moved to the
  `standings` tag, the relay had kept only the old `results` tag for
  good, and swept each result a day after storing it. Results swept
  before this are not recovered. (2026-10-11, #11)
- A deal seed shorter than 32 bytes is refused rather than panicking.
  (2026-10-11, 21b4fb1)
- A signed table event whose body is not its kind's shape is dropped at
  parse. (2026-10-11, ddcb3b8)

### Security

- A seated player can no longer silence another seat. The referee took
  a table event under whatever id it claimed, so a player could sign an
  event of their own under the id another seat's next move would carry,
  get it logged first, and have the real move refused as a duplicate;
  the seat then timed out to a bot. Every table event's id is now
  checked to be the hash of what it says, as the start's already was.
  (2026-11-01, #47)
- A seated player can no longer grow a table's log until the table
  fails for everyone. Each person's events may fill only a set share of
  the log (the house's are not held to it), ticks are taken only from
  the table's own people and its house and none once the result is in,
  and an event nested deeper than any table event goes is refused.
  (2026-11-01, #47)
- Only the house can make a rated table. Nothing tied a table's
  `rated` to a pool seating, so a subscriber could start a rated table
  naming anyone, and the house would play out the absent seats and
  rate them as having left. A pool table's salt is now a value only the
  house can make, and the house serves no rated table without it; at a
  table it did not seat, it publishes no result while a person there
  never said anything. Rated games already in play when this house
  first deploys stall without a result, since they were seated
  without that salt. (2026-11-01, #47)
- A malformed deal message can no longer crash the house. Inputs of the
  wrong size were read past their end by the deal library, and a
  shuffle proof with a list of the wrong length made it abort the whole
  process; both are now refused. A device's proofs are bound to the
  cards they are about, and the keys message no longer carries key
  shares wrapped under the same pad as the escrow piece, which leaked
  part of each deal secret. (2026-11-01, #47)
- One paid checkout makes one account. Two deliveries of the same
  Stripe event at once could each make an account for one
  subscription; the account is now found or made in the subscription's
  own turn, and Stripe is asked to send again when that fails for a
  while. An account's turn acts only for that account's devices, and
  backup codes tried from outside an account no longer use up its
  hourly allowance. (2026-11-01, #47)
- Names other players' devices send are cleaned before they are shown:
  the characters that reverse the direction of text (which could make
  "Bob wins" read as something else, or spell a refused word
  backwards), control characters and line breaks are dropped, and every
  name is cut to the length the profile allows. Names in look-alike
  Cyrillic or Greek letters are held to the reserved-name filter too.
  (2026-11-01, #47)
- The relay carries a view of a watched table only from one of its
  people, so a stranger can no longer show watchers a game of their
  own. A socket that has not answered the relay's challenge can hold
  only a bounded amount, LOG requests count against a socket's rate,
  and only an answer to the socket's own challenge is checked. The
  service reads no request body past its bound, and quotes a report's
  note in the operator's email so that it cannot pass for instructions.
  (2026-11-01, #47)
- Releases are held to reviewed code throughout. A production web
  build takes its keys, relays and sign-in IDs from
  config/openhearts.json alone, never the shell; the release gate
  refuses untracked files, and ignored files the site would publish,
  and refuses when origin/main cannot be fetched; store builds are
  gated too; and `OH_RELAY_DRY_RUN`, which skipped the relay's gate, is
  gone. `oh key mint` sets the service secret without ever showing it.
  Previews get their own sign-in key and no TURN token. Wrangler runs
  from a lockfile, and deploys are given only the Cloudflare
  credentials. (2026-11-01, #47)

- Previews hold none of production's secrets. A preview runs whatever
  branch was deployed to it, and it held production's service secret,
  which `oh secret set` put on every environment. It now signs with a
  pair of its own, and `oh secret set OH_SERVICE_SECRET` sets
  production's alone. (2026-10-24, #38)
- A kept game's record carries, with each removal, the signed word of
  everyone who backed it, and whoever opens the game counts the
  removal's majority from those signatures. Before, a record named a
  removal's backers by key alone, so one sent to be kept could claim a
  majority nobody gave, such as for the game's end. The service keeps
  records only in the new form; games kept before still open, checked
  as they were. (2026-10-13, #27)
- `?e2e`, which loosens the app for the browser suites, is honoured only
  on a page served from this machine. (2026-10-11, 6c10b57)
- A backup juror's mark is checked in constant time, as an HMAC is.
  (2026-10-11, efcfa4f)
- The whole repository history was scanned with `detect-secrets`, and no
  credentials were found. (2026-10-01, bb279cc)
