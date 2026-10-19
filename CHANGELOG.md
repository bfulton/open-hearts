# Changelog

Notable changes to Open Hearts. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Open Hearts has
no numbered releases yet: every deploy of `main` is the current version,
so each entry gives the date it landed and its commit or, for a change
squashed from a pull request, the pull request's number.

## [Unreleased]

### Added

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
- Pictures are checked as the relay first carries them, by Cloudflare's
  Workers AI, for nudity, gore and hate symbols. One the check flags is
  withheld from everyone within a couple of minutes, and the daily email
  shows it first; `./oh picture allow` puts one back. (2026-10-19, #32)
- Each new picture is checked by Microsoft's PhotoDNA against known
  images of child sexual abuse before the relay carries it, asked from
  one object kept in the United States. A match is never shown: it is
  withheld, each account that put it out is held and terminated, its web
  subscription ended with nothing refunded, the match is reported to
  NCMEC's CyberTipline, and the operator is emailed what was done, all
  without waiting on the operator. Each step is tried again until it is
  done, and any failure emails the operator. Off until PhotoDNA's key is
  set; reports are filed once NCMEC's credentials are, and until then
  the email says to file one by hand. (2026-10-19, #32)
- Every new picture is copied to R2 and emailed to the operator once a
  day, account by account, with the commands to take it down.
  (2026-10-19, #32)
- Names that are obscene or slurs, in five languages, are refused by the
  app, the service and the relay, matched as whole words so real names
  stay. (2026-10-19, #32)
- A legal hold keeps an account's data for a year at the least after a
  report the law requires, with a copy of each picture the account put
  out in its last 30 days, kept where only the operator reaches it.
  `docs/how-to/handle-abuse-material.md` is the procedure for child
  sexual abuse material that PhotoDNA doesn't catch. `./oh picture
  report` has the relay handle a picture the operator found as it does a
  match, with a report saying the operator looked at it. For what is
  done by hand, `./oh account find` takes a picture's SHA-256 or address
  to the accounts that put it out, and `./oh picture hide` withholds one
  an account no longer uses. (2026-10-19, #32)
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

- The 17 games kept before seats carried licences (4 to 6 October
  2026), whose names nothing but a device's key tied to an account, and
  with them `service/tool/forget.mjs` matching a seat by the account's
  devices. Every game kept since names each person's account by the
  licence at their seat, and the service now refuses one that does not.
  (2026-10-12, #15)
- The path that adopted subscriptions from before accounts, after a
  count showed none in production. (2026-10-11, 0520e34)

### Fixed

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
