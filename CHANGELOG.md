# Changelog

Notable changes to Open Hearts. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Open Hearts has
no numbered releases yet: every deploy of `main` is the current version,
so each entry gives the date it landed and its commit or, for a change
squashed from a pull request, the pull request's number.

## [Unreleased]

### Added

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

- The path that adopted subscriptions from before accounts, after a
  count showed none in production. (2026-10-11, 0520e34)

### Fixed

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

- `?e2e`, which loosens the app for the browser suites, is honoured only
  on a page served from this machine. (2026-10-11, 6c10b57)
- A backup juror's mark is checked in constant time, as an HMAC is.
  (2026-10-11, efcfa4f)
- The whole repository history was scanned with `detect-secrets`, and no
  credentials were found. (2026-10-01, bb279cc)
