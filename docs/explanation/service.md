# The service

This page explains what runs on our side and why it is shaped the way
it is. Every handler, host, statement and stored row is in the
[service reference](../reference/service-api.md), and every setting in
the [configuration reference](../reference/configuration.md).

The service is deliberately small. The game is peer to peer
([multiplayer](multiplayer.md)), the deal is verifiable
([the fair deal](fair-deal.md)), and matchmaking, results and ratings are
the players' own business on the relay ([live play](live-play.md)). What
runs on our side:

- **The Pages worker** (`service/functions/`): accounts, licences, the
  shop, TURN credentials, remote config and game records.
- **The relay worker** (`service/do/`): a Durable Object per tag
  ([the relay](relay.md)), which carries only an account's device in
  use; the `Household` object, one per account; and the backup jurors
  (`service/bin/juror.dart` in a container).

None of it is in a game's latency path.

## Where the app is

`service/functions/worker.mjs`, published in `_worker.js/`, answers
`/api/<name>` and hands every other path to the static assets. One Pages
project and one deployment serve the site, the app and the handlers,
and the worker routes by host
([hosts](../reference/service-api.md#hosts)). `play.openhearts.game` is
the app, at the root, with the handlers. `openhearts.game` is the site
alone: it answers no handler, and serves nothing of the app, since the
build served from there would be the app at another origin, with no
device in it. A preview serves the site at its root and the app under
`/play/`, never sends anyone to production, and plays live on a relay
of its own ([previews](#previews)).

**The app calls the handlers on its own origin.** Every address the app
makes for the service is its page's origin plus `/api/<name>`
(`handlerFor` in `licence.dart`, `turn.dart`), so at
`play.openhearts.game` it calls `play.openhearts.game/api/…`. That keeps
the three things that care about origins simple:

- **No CORS.** The calls are same-origin, so there is no preflight to
  get right and no second origin whose `Origin` header a handler has to
  trust. (`play.openhearts.game` is in the allowed list anyway, for
  anything else of ours that asks.)
- **Stripe's return addresses** must be on the origin the checkout was
  asked of (`sameSite`). Asked of the app's own origin, the app's own
  page is one, with no list of other origins to accept. The billing
  portal's return is the same.
- **Signed requests** carry no cookie and no session, so nothing
  depends on which host a device calls.

Everything else that calls the service calls it there too: Stripe's
webhook (`infra/stripe.mjs`), the App Store's and Google Play's
notifications, Sign in with Apple's, and the health monitor
(`observability/`). So there is one address for the service, and the
rate limit on `/api/` is on that host (`infra/cloudflare.mjs`). Sign in
with Apple's return address is the document's base,
`https://play.openhearts.game/`, and the Services ID names only that
host and that address. The relay checks no `Origin` header.

### The device, carried over

What makes a device itself is in the browser's `localStorage` under
`flutter.*`: its secret key, licence, name and picture (its copy of its
account's, for a subscriber), records and settings. Storage is per
origin. The app was first served at `openhearts.game/play/`, so a device
that played there would be a new player at `play.openhearts.game`, and a
subscriber's device no device of any account. So it is carried over,
once, in the browser:

1. On a load at `play.openhearts.game` with no `flutter.identity_secret`
   and no `oh.carried` mark, `app/web/carry.js` runs. It is a script
   before the bootstrap, so it runs before Dart reads storage. It puts a
   hidden iframe of `https://openhearts.game/carry`
   (`site/public/carry.html`) on the page and, once it loads, asks it
   with `postMessage` addressed to exactly `https://openhearts.game`.
2. The carry page answers only a message from its parent at exactly
   `https://play.openhearts.game`, and only when asked: it posts its
   `flutter.*` entries back, addressed to exactly that origin. The
   worker lets that origin, and no other, frame it
   (`frame-ancestors https://play.openhearts.game`, no
   `X-Frame-Options`), where every other page is framed by nobody.
3. The app takes an answer only from that frame at that origin. It
   writes the entries if there is still no key (another tab may have
   made one), never over an entry already there, marks the carry done
   (`oh.carried`), and starts the app. `flutter_bootstrap.js` waits on
   this, and on nothing else.
4. It waits for the old origin's page to load (`LOAD_MS`), then for its
   answer (`ANSWER_MS`). A carry that does not answer in time is not
   marked done and the app boots. It makes a key of its own, and with a
   key there the carry is never tried again. So the wait for the network
   is long, and costs only a slow first load; a page with nothing to
   carry answers in milliseconds.

The two hosts are one site (same scheme, same registrable domain), so
the frame reads `openhearts.game`'s own storage, not a copy partitioned
under the top-level site, in Chromium, Firefox and Safari alike.
`e2e/move.mjs` checks this in Chromium with the rig's stand-ins, which
are one site in the same way. Nothing is deleted at the old origin, and
what is carried never leaves the browser.

## Signed requests

A device's key is public: it signs everything the device says at a
table, and the relay hands those events to anybody. So every handler
that acts for a device takes a request signed by that key, over the
handler's name, the second it was made and whatever the request asks
for ([signed requests](../reference/service-api.md#signed-requests)).
What that stops, and what it accepts, is in the
[security model](security-model.md#requests-act-only-for-the-key-that-signed-them).

## Licence

A device holds a **licence**, not a receipt: a statement of its key, its
account and the last day it is good for, signed by the service key
(`OH_SERVICE_SECRET`). The app checks it against `OH_SERVICE_KEY`, the
public half compiled into the build (`packages/table/lib/src/licence.dart`,
`app/lib/entitlement.dart`). A licence for another key, past its day, or
signed by anything else is not a licence. A build compiled without a
service key treats every device as unlicensed, never as licensed by
whoever answers.

The licence is also how every peer knows whose a device is. A device's
key never leaves it and none is held for it; the licence vouches that
the key is one of an account's devices. It rides in every seat of a
start event, in a waiter's and a room member's beats, in a watcher's
request and in each line of a result, and every peer checks it against
the same compiled key ([live play](live-play.md)).

A licence is short (`licenceDays`), never runs past what was paid for,
and is renewed while the subscription lives, so an ended subscription
needs no revocation list. The app reads its stored licence before the
first frame and asks the service afterwards, so it plays offline until
the licence's date. The worker checks its own signature against
`OH_SERVICE_KEY` and answers 503 for a mismatched pair
([rotate the service key](../how-to/rotate-the-service-key.md)).

## Payment

Live play is a yearly subscription, paid up front, at the price in
`config/openhearts.json` ([changing the terms](#changing-the-terms)).
The rest is free: solo play, the records, the verifiable deal and the
engine. The price is yearly because a card fee's fixed part would be
most of a monthly price.

**Web: Stripe, sold through Link.** Every checkout is a Managed
Payments one (`managed_payments[enabled]`): the buyer buys from Link
(Sold through Link, LLC), Stripe's merchant of record, which charges
and pays over the tax of wherever the buyer is, keeps to their
country's rules for buying online, such as the EU's and the UK's 14
days to cancel, and answers their questions about the payment. So Open
Hearts registers for no sales tax or VAT anywhere, and can sell
anywhere Link does. Link's support may refund a payment within 60 days
of it without asking us, and the terms say a refund ends the
subscription, so a refund of any payment for one of our subscriptions,
whoever makes it, ends that subscription (`endRefunded` in
`service/functions/stripe.mjs`, from the webhook's `charge.refunded`).
Whether Stripe sells this way is a setting in Stripe's Dashboard that no
API reports; `./oh verify` makes a checkout through Link and expires it,
which proves it. The service calls Stripe in the webhook's API version
(`STRIPE_VERSION`), not the account's default.

`checkout` writes the device's key into the session's
metadata and the subscription's metadata, so renewals carry it too. The
return address must be on the origin the checkout was asked of, which is
the app's own ([above](#where-the-app-is)), and the app only
leaves for Stripe's own hosts. The app's subscribe screen states the
price, the yearly renewal and how to cancel beside its button. On
Link's checkout, in the app's language (`checkoutLanguage`), nothing is
paid until the buyer ticks Stripe's box agreeing to the terms and the
privacy policy, and the line under the button says that subscribing
authorizes Link to charge them until they cancel. The email that
follows says what was bought, how it renews and how to cancel
(`mailerOf` in `service/functions/household.mjs`). California's
automatic renewal law asks for all of it. A Managed Payments checkout
takes no custom text, so the box's words are Stripe's, and it takes the
box only while Checkout's Legal policies setting is on; Stripe refuses
a checkout otherwise, which `./oh verify` shows. The webhook binds the device once the
session is paid, and the subscription's own events carry its dates.
`stripePrice` in `config/openhearts.json` names the Stripe price, by id
or lookup key. A checkout sells it only when it is the price the terms
state, a year at `price` (`shopPrice` in `service/functions/stripe.mjs`);
the answer is cached briefly (`PRICE_KEPT_MS`). Tax is added on top
of that price (`taxBehavior` in `infra/stripe.mjs`), as the terms say,
and Link shows it in the buyer's own currency.

**Phones: the store.** The phone buys in its own store and sends the
proof to `store`: an App Store signed transaction, or a Google Play
purchase token. The subscription id is `apple:<original transaction id>`
or `google:<digest of the token>`. The app tags each purchase with a
name derived from its key, so the store's records name the device
without naming the person
([hashed strings](../reference/service-api.md#signed-requests)). The
paying device moves onto what it paid for, with its account, where
nothing else is paid up there. Another device presenting the same proof
(a restore on a new phone) joins that account within its limit.
Renewals, lapses and refunds arrive at `apple` and `play`, and for Play
the purchase is fetched again. Neither store is ever final, since a
lapsed subscription can come back. Without its identifiers (`apple`,
`google` in `config/openhearts.json`), each store answers 503.

How each proof and webhook is verified, and why events out of order
cannot revive a subscription, is in the
[security model](security-model.md#payments).

## Accounts

A subscription buys an **account**: a random id (`newAccount`), made
when the subscription is first paid for (a Stripe checkout, an App Store
or Play purchase), with the paying device on it. The account is the
person: a seat, a name, a rating and a result are the account's,
whichever of its devices played. Solo play needs none. A subscriber
whose subscription lapses and who buys again, with nothing else paid up
on the account, gets the same account back.

An account carries a few devices (`mostDevices`), and any of them can
drop another or open the billing portal. A device comes into an account
in one of three ways:

- **A household code.** `ticket` makes a one-use code, good for
  `ticketMinutes`. It is shown as a QR of a link into the app and as
  text. The other device opens the link, scans it in the app (the
  platform's scanner, or BarcodeDetector or the bundled ZXing port on
  the web), or types it. Asking again while a code has
  `ticketReuseMinutes` left returns the same code. The household's size
  is checked when the code is spent.
- **Backup codes.** Each account has a few (`BACKUP_CODES`), each good
  for one join, sixteen characters of Crockford base32 that a person can
  read and type (`backupCode`). They are the account's recovery secret:
  one entered on any device brings it into the same account. They are
  made when the account is paid for and emailed to the checkout's
  address, which is read from Stripe and not kept, in the email that
  says what was bought (`backupsMade`). Each web purchase gets that
  email once, a lapsed account's bought again included, even with
  every code used. Any device of the
  account can show them, replace them all, or email them again. Email
  goes through Cloudflare Email Sending (`EMAIL`, from `OH_MAIL_FROM`,
  no reply-to). A store subscription has no address, so its codes are
  only shown.
- **Sign-in.** A sign-in with Apple or Google is linked to one account,
  and an account to one sign-in; it is a backup code that is never used
  up. `attest` links the sign-in to the account the device is in (409 if
  it is linked to another account, or the account to another sign-in).
  `supersede` brings the device into the account the sign-in is linked
  to, by a backup code's rules (404 if it is linked to none). No key
  moves. Google's audience is `google.webClientId`; Apple's are
  `apple.bundleId` and `apple.servicesId`, since Apple's token names the
  bundle id on an iPhone and the Services ID on the web. How a token is
  checked is in the [security model](security-model.md#sign-in).

  The app (`app/lib/net/sign_in.dart`, `provider_tokens.dart`) offers
  Apple on iOS and the web and Google on Android and the web, each only
  in a build compiled with its identifier (`apple.servicesId`,
  `google.webClientId`, compiled in by `deploy.sh`). Without them there
  is no sign-in on the screen. On iOS it uses Sign in with Apple; on
  Android, Credential Manager (through `google_sign_in_android`, not
  `google_sign_in`, whose web half loads Google's script into every
  page); and on the web, Apple's JS popup and Google's own button, whose
  scripts are fetched only when a sign-in is on the screen. On the
  Subscription page a subscriber is offered a sign-in, which links it to
  the account; a sign-in linked to another account brings this device
  into that one only when the subscriber says so. A device with no
  subscription signs in to come into its account. The device keeps only
  which provider it signed in with.

A code or a sign-in never takes a device out of another account whose
subscription is still paid up. The app asks "Join this subscription?"
before spending a code. To move, a device drops itself first. A device
whose subscription has ended is free to join. Dropping a device deletes
its binding and its entitlement row, and cuts it off at the relay if it
was the device in use. The licence it already holds runs out on its own.
When a subscription ends, its account's devices' entitlement rows are
written down too, so a refund takes effect at each device's next ask.

**One account at a time.** KV has no compare-and-set, so every change
to an account (a code, a claim, a drop, its device list, its device in
use) goes through one **Household** Durable Object per account, which
handles them one at a time. A subscription has a turn of its own, the
object named `sub:` and its id, where its account is found or made
exactly once. The class is exported from the relay worker and bound to
the Pages project as `HOUSEHOLD` (a preview's to the preview relay's)
and to the relay worker under the same name. Without the binding, as in
the tests, an in-memory queue in the isolate does the same. Each kind of
operation has an hourly allowance per account, counted in that queue
([service settings](../reference/configuration.md#service-settings)).

What the object writes, the handler that asked it takes from the
object's answer, not from KV. KV is eventually consistent: the object
runs where its account was first asked for, and a handler somewhere
else can be shown what was there before for up to a minute, a row it
found missing included. So a device brought in, by a code, a store
purchase or a sign-in, is licensed from the entitlement row the object
wrote. After that, the device shows its licence with every request. The
service signed that licence, and it names the account:

- A handler that asks the account's object next asks the account the
  licence names, and the object, which knows the device, decides. These
  are taking the account up, the profile, the devices, the backup codes,
  a code for another device, and linking a sign-in.
- A handler that decides by itself goes by the store, as before, where
  the store backs the licence. Where the store names another account or
  none, it asks that account's object whether the device holds live
  play. These are TURN, a wait for a person, a report, and a game's
  record, sent or looked at.
- Deleting an account goes by the store alone. It ends the account's
  subscriptions and takes its name off its games before its object is
  asked anything.

A licence lasts up to a month, so a device dropped from its account
still holds one. The object refuses it. What an object is asked on a
licence the store does not back is counted against an allowance of its
own, the size of the reads', so such a device spends nothing of what
the account's own devices have.

### When Apple says a sign-in is gone

Sign in with Apple tells `apple-id` when a person stops using it with
the app (in their Apple Account's settings: Sign in with Apple, Stop
Using) or deletes their Apple Account, and when they turn forwarding to
a hidden address on or off. The notice is a token checked as an ID
token is ([security model](security-model.md#sign-in)).

- **`consent-revoked`, `account-deleted`** (and `account-delete`, which
  Apple's page has also named): the sign-in found by the HMAC of its
  subject is unlinked, in its account's turn, where it was linked. It
  brings no device in after that (`supersede` answers 404), and the
  account can be linked again, to it or to another sign-in. Nothing else
  changes: the account stays, with its devices and backup codes, which
  still bring devices in, and its subscription, which is the store's or
  Stripe's to end.
- **`email-disabled`, `email-enabled`**: we hold no email from Apple,
  so nothing changes.

Anything authentic is answered 200, whatever its type, so Apple does
not send it again. An unlink that could not be done is a 503, to be
done when it comes again. Nothing is kept to spot a notice seen before
(`jti`): one sent again only unlinks what is already unlinked. It is
quiet: the operator is not mailed, and `measure` counts it as
`apple-id`. Without the Apple identifiers or `OH_ID_HMAC` it answers
503. Apple is told the address by hand
([register the webhooks](../how-to/set-up-webhooks.md)).

### One device at a time

An account plays on one device at a time, and the newest device to take
it up wins at once. The app takes the account up when it opens, and
again on the person's *Use it here*; each is `activate` with `want:
open` (or `take`), and a renewal while open (`InUse.renewEvery`) is
`want: renew`. In the account's turn, the device asking is made the one
in use and the account's **epoch**, the count of times it has been taken
up, goes up by one; a renewal by any device but the one in use is a 409.
Taking the account from a device that said it is at a table (its
renewals carry the table, `seated`) is asked about first: `open` answers
409 `seated`, the app asks "You're in a game on another device. Continue
here? That game will be lost.", and only `take` goes through.

The device in use is given an **activation**: a statement of the
account, the device's key, the epoch and when it runs out, signed by the
service key ([signed requests](../reference/service-api.md#signed-requests)).
It runs out within the hour (`ACTIVATION_S`), and never past the day the
subscription is paid to.

**The relay enforces it, rather than asking.** A device told to stop
could be a modified one that does not. So the relay asks every socket
who it is (NIP-42: a challenge, answered by an event the device's key
signs, carrying its activation), holds whatever the socket sends until
the answer is in, and carries nothing for a socket without a current
one (`serviceGate` in `service/do/relay.mjs`). Three things keep a
superseded device off it:

- Each relay object keeps the newest epoch it has seen of each account,
  so showing a later activation closes every socket of that account's
  earlier one there, and an earlier one is refused.
- As a socket answers, the object asks the account's own object whether
  that activation is still the one in use, and the account's object
  remembers which relay objects the device was seen at. When the account
  is taken up, it tells each of them (`/revoke`) to close the old
  device's sockets at once, wherever the old device is: presence, a
  pool, a table or a watch.
- An activation runs out within the hour, and an answer that has run
  out is asked for again.

The device itself hears it sooner where it can: the relay's
`superseded:` notice, a 409 at its renewal, or the other device's
presence, which carries the later activation. It then leaves the
relays, any table it sits at, juror duty, the pool and anything it was
watching, and shows "Open Hearts is now open on another device" with
*Use it here*. Its signed leave goes by whatever channel is still open,
and the table's ordinary handling takes the seat however it goes: a bot
in the seat, scored as a leave in a rated game.

The service is the authority because it is the one party every device
of an account already trusts and already asks. An activation is the
account's turn's word, so two devices can never both hold the current
one. A backup juror answers the challenge with an HMAC of its key under
`OH_JUROR_SECRET`, which the relay holds too; backup jurors belong to no
account.

### The account's profile

The name the others see, and the icon and colour or the picture they
see it on, are the account's, as its seat and rating are: every device
of the account shows the same, and a change on one reaches the others.
The service keeps it in one row per account, with a version that goes
up by one at each write ([profile](../reference/service-api.md#profile)).

`profile` is one signed handler. Asked with nothing, it is a read, for
any device of the account while the subscription stands, counted among
the account's reads. Asked with a profile, it is a write, only from the
account's device in use, with an allowance of its own
(`profileWritesPerHour`) so that a person changing their mind never
spends what a code or a claim needs. The profile is the device's own
JSON text, which is also the request's signed *what*, so nobody else's
request writes it. The text is taken only in the shape the app makes,
and a test holds the worker's limits equal to the app's.

**A new picture is checked and kept as it is written.** The account's
turn, which runs in the relay worker, asks the checker of known images
in use, Arachnid Shield or PhotoDNA, about it and has a model look at
it before the profile keeps it, and keeps a copy of each picture the
account sets apart, for the operator, until a year after it stops
being the account's. A picture that matches a known image of
child sexual abuse is not kept, and the profile is saved without it. The
relay carries only the account's picture now ([an account's
pictures](relay.md#an-accounts-pictures)).

**The last write wins.** Each write is the next version, whatever
version the writing device had last seen. There is nothing to merge in a
name, writes come only from the device in use, which is the one in the
person's hand, and a compare-and-set would only turn a change made
offline into a refusal the person has to make again.

**The app** (`app/lib/net/account_profile.dart`) keeps the profile on
the device, so the front door draws it with no network, and keeps beside
it which account and version it last matched:

- A change on the profile page is kept on the device at once, marked
  unsent for the account, and sent. Unanswered, refused as not the
  device in use, or over the allowance, it stays marked and is sent at
  the next chance: the next start, this device becoming the one in use
  again, the app coming back to the foreground, or the next config ask.
  A profile the service refuses as malformed is not sent again.
- At start, behind the licence, and whenever the device becomes the one
  in use, a licensed device sends its unsent change if it has one.
  Otherwise it reads the account's and takes it if its version is newer
  than the one it last matched, or if it last matched another account or
  none. A change made while a read was on its way wins: it is sent next.
- Each activation's answer carries the profile's version, and the
  device in use reads again when that moves. Only the operator changes a
  profile from anywhere but the device in use
  ([suspending an account](#suspending-an-account)), so this is how such
  a change reaches it: at its next renewal, within 20 minutes.
- **Joining** (a household code, a backup code, a sign-in, a store
  restore) ends in a licence for another account, which the app watches
  for: the account's profile replaces the device's, and an unsent change
  for the account it left is let go.
- **An account with no profile yet**: the first of its devices to read
  finds none and sends its own, if it has a name or a look, and the
  others take it from there. Two at once both write, and the later is
  the profile.
- A device with no subscription keeps its profile to itself. One that
  leaves an account, or is dropped, keeps the last profile it had.

What is published at tables is read from the device's copy
([live play](live-play.md)).

### Names the others see

A name the others would see is refused if it has a word on the lists of
obscene and offensive words in `third_party/ldnoobw/`, in English,
Spanish, Portuguese, German or French, or one of a few words refused
even inside another word. So is a name that would pass for Open Hearts
itself or the people who run it: the game's name, and words such as
*admin*, *moderator*, *support*, *staff*, *official* and *operator* in
the same five languages. Words are compared in lower case, with
accents folded and with digits and signs written for letters read as
letters, so `5h1t` is read as *shit*. Words are matched whole, so
*Cassandra*, *Scunthorpe*, *Staffan* and *Supporter* stay names. Entries that would refuse
real names are left out, and the folder's README says which and why.
What the lists miss, a report catches.

The filter is one set of steps written twice and held to the same
answers by one file of cases (`service/functions/names.vectors.json`):

- **In the app** (`app/lib/names.dart`), the profile page says under
  the name, as it is typed, that the name is not allowed, and keeps the
  last allowed name when the page is left. A refused name kept on a
  device from before the filter is played as no name, so live play asks
  for another, and it goes to the account as none.
- **In the service** (`service/functions/names.mjs`), a profile with a
  refused name is not kept: the write is refused with
  `not an allowed name`, which the app does not send again. A kept
  game is kept without a refused name beside it.
- **At the relay**, an event naming somebody with a refused name is not
  carried ([refused names](relay.md#refused-names)).

### Deleting an account's data

A player deletes their account in the app, from any of its devices:
**Delete account** on the subscription page, there for a device that
holds a licence, holds one that has run out, or is suspended. The
service also deletes one on request (the privacy policy's choices),
when the operator runs `./oh account delete`. Either way the account is
forgotten.

Its name comes off every kept game it played, found by the licence at
its seat (`anonymizeGames`), which stays the other players' game: the
names are kept beside a record unsigned, so the record verifies as
before. A kept game notes the accounts at its seats beside it in R2
(`accounts`, in its custom metadata), so the worker reads only the games
that name the account; a game kept before games noted them is read
whatever it names. The account is marked forgotten first, so a game kept
later, such as one its last licence let it finish, is kept without its
name. Every row kept for the account is deleted (`forgetAccount`): those
under `ACCOUNT#` (its devices, code, backup codes, sign-in, device in
use, profile, and any suspension or name and picture held), each
device's `ENTITLEMENT`, the rows its codes and sign-in are found by, and
the `SUB#` rows of every subscription it has had, which its `META` row
names, the one before a lapsed subscriber paid again among them
(`before`).

From the app (`deleteRoute` in `service/functions/worker.mjs`), the
service first ends in Stripe each web subscription of the account still
running, and the time left on it goes with it, as the terms say. A
subscription bought in a store is the store's to end: the app says to
cancel it there. Then the games, and then the rows, in the account's
own turn (`deleteAccount` in `service/functions/deletion.mjs`), where
its device in use is cut off at the relay with the reason `deleted:`
and the `Household` object keeps only the epoch it counts devices in use
by. A run that stops part way finds the account still there when the
device asks again, and goes on. A kept game that would not be written
back as it was sent keeps the name, and the operator is emailed which
(`alertUnwritten`). The device then forgets everything it keeps and
starts afresh (`app/lib/start_afresh.dart`): the page loads again on the
web, and a phone build asks to be closed and opened again.

Stripe tells the service of the subscription's end after the account is
gone. Its `SUB#` row comes back as the note that it ended, with no
customer and no account (`record` in `service/functions/stripe.mjs`), so
that a late event about it is turned away. Under a legal hold
(`holds.mjs`), nothing is deleted or ended: the asking is noted, and the
app is answered as for a deletion.

From the operator's command, a subscription still paid up is cancelled
first. Where the `Household` object runs, its note of the device in use
(its key, the epoch, times, the table it said it sat at, the relay
objects it was seen at, and whether the account was suspended) is in the
object's own storage and is not reached from outside. It is written over
the next time the account is taken up, which after deletion is never,
and it holds no name or picture.

Either way, its results stay on the relay, under its account number,
which nothing left in the service ties to the person; a result cannot be
changed in any case, since every copy is signed by the device that
published it
([delete an account's data](../how-to/delete-an-accounts-data.md)).

### Suspending an account

The terms let the operator suspend an account from live play, end it,
and take its name or picture off, in their sections "At a live table",
"Ending these terms" and "Copyright". `./oh account` asks for it
([suspend an account](../how-to/suspend-an-account.md),
[end an account](../how-to/end-an-account.md)), and
`service/functions/suspension.mjs` carries it out. What a suspension or
an ending does in Stripe, the command does itself, with the operator's
own key: the service's key can't cancel or refund.

**In the account's turn.** The account's device in use, and the relay
objects it was seen at, are known only in the account's turn, where
`Household` keeps them. So that is where a suspension is carried out,
one after another with the devices' own requests, and where the device
in use can be cut off at once. The command reaches the store from
outside, as `./oh account delete` does, but not the object. It writes an **order** into the
store (`ORDER#<id>`, which KV deletes after `ORDER_KEPT_S`) and asks the
service to carry it out (`order`). The handler reads the order before it
wakes anything, so a request that names no order does nothing, and only
someone who can write the store, the operator, can make one; no new
secret is needed. A carried-out order is deleted. Each act can be
carried out twice to the same end, since the command asks again when an
answer is lost or KV has not shown the order yet.

**Suspended**, the account is marked (`SUSPENDED`), and each of its
devices' `ENTITLEMENT` rows is flagged. Every handler that asks for a
subscription then refuses the device at the one read it makes
(`entitlementOf`): its licence, activation, profile, TURN credentials,
game records and review. Checkout refuses to sell it one. A device
brought into the account later is flagged as it joins, and a
subscription that one of its devices buys stays with the suspended
account rather than making a new one (`accountFor`). The device in use
is cleared and the epoch goes up, as when another device takes the
account; the relay objects it was seen at are told to close its sockets
(`/revoke`), with the reason `suspended:` rather than `superseded:`, and
the account's turn says the same whenever a relay asks about one of its
activations (`seenAt`).

**The app** hears it in one of three ways: the relay's reason, a 403
with `suspended` when it next asks to be the device in use, or a 403
with `suspended` at its licence check. Each does the same: live play
shuts as on a superseded device (the table, the pool or room, any watch,
and juror duty), the licence comes off the device, and where the app
would sell live play it says that the account is suspended and where to
ask why (`InUse`, `Entitlement.suspend`). Playing alone is untouched.

**Lifted**, the mark and the flags go, and each device gets its licence
again at its next licence check.

**A name or picture taken off** is held beside the profile (`HELD`), so
that a counter-notice can put it back, and the profile's version goes
up, which the device in use hears at its next renewal
([the account's profile](#the-accounts-profile)). A name taken off is
also taken off the account's kept games (`anonymizeGames`), which
putting it back doesn't undo. A picture taken off is withheld at the
relay too ([withheld pictures](relay.md#withheld-pictures)); a name the
relay already holds stays for its usual day.

**What it can't do.** An account is a number tied to device keys and
payments, not to a person. A device with a new key, or one dropped from
the account, can subscribe again as a new account. Only checking who
people are would stop that, and the service checks nobody.

## TURN

`turn` mints Cloudflare Realtime TURN credentials, which last
`turnTtlS`, only for a device whose subscription stands, since TURN is
billed by the gigabyte. A device just brought in is found by its
licence, as [above](#accounts). Without the TURN secrets it answers
503, and the app makes no data channels and plays over the relay:
channels go through TURN or not at all, so no peer learns another's
address ([multiplayer](multiplayer.md)).

## Game records

A player at a finished table can send its record to be kept. The first
copy is kept, gzipped, in R2 (`OH_RECORDS`). Who may send one, and how
many an hour, is in the
[service reference](../reference/service-api.md#handlers). Looking at one
is live play: `review` serves it only to a device with a subscription
that is its account's device in use, and not while the account sits at
that table. The worker keeps only seats the app would show: each
person's carries the service's licence for its key, as every seating
does, which is what ties a name beside the record to an account. It
vouches for nothing else. Every viewer replays the record through the
verifier before showing a card
([game records](live-play.md#game-records)).

## Storage

Everything the worker keeps is in one KV namespace, `OH_STORE`, looked
up by key and never scanned
([storage](../reference/service-api.md#storage)). Where the `Household`
object runs, the account's device in use is kept in that object's own
storage instead of a row. A provider's identifier is stored only as an
HMAC, and nothing on the device's side leads back to a provider.
Entitlement is copied to each device so that a licence is one read.
Cards, plays, game state, ratings and email addresses are not stored.

## Changing the terms

The terms of use, the privacy policy and the price change only through
one process ([change the terms](../how-to/change-the-terms.md)), and
each step of it is checked by something that runs whether or not
anyone remembers it:

| Check | Where | What it stops |
|---|---|---|
| The text is what the newest entry in `site/ledger.json` fingerprints. | CI (`site/ledger.test.mjs`) and the deploy (`ops/gate.mjs`) | A change to either document, or to the price they state, without its entry: its day, its kind and what it says to subscribers. |
| An entry on `main` is never changed or taken out. | CI | A change slipped into an entry already reviewed. |
| The terms' price, the front page's, Stripe's definition and the app's are `price` in `config/openhearts.json`. | The site's build, `infra/stripe.mjs`, CI | One of them saying another price. |
| The site serves a version the ledger has, and the newest to go live is dated today. | The deploy | Publishing outside the process, and a stale "Last updated". |
| A material change goes out only once the stores were told, while an app is in its store. | The deploy | Texas's notice to the stores being missed. |
| Every device is shown a material change from the day it is published, and each web subscriber is emailed it. | `/api/config`; `./oh terms notify`, which no deploy runs, and `./oh verify`, which fails until every web subscriber was told | A change nobody was told of, and a deploy emailing everyone as a side effect. |
| The terms apply a material change to a subscription only from its first renewal at least 30 days after its subscriber was told. | The terms, and the email, which names that renewal (`APPLIES_AFTER_DAYS`) | A change applied to someone with no time to read it or cancel. |
| A checkout sells only at the price the terms state. | The service (`shopPrice`), and `/api/health` | A price edited in Stripe's dashboard being charged. |

Which version is live is read off the site itself, every page in every
language, so a deploy that skipped all this is found by the next. What
stays outside: someone with Stripe's dashboard can still move an
existing subscription to another price, and store prices are set in
App Store Connect and the Play Console, where Apple and Google run their
own notices.

The remote config has no say in any of it: the price, and where the
terms and the privacy policy are, are not remote-config fields.

## Remote config

Some things have to change for every device at once, faster than a
release: closing live play, a banner, the relays, the table's clocks,
how long the app waits on the network. `config` serves one row the
operator writes ([remote config](../reference/configuration.md#remote-config);
[change remote config](../how-to/change-remote-config.md)), and beside
it the notices of a change to the terms
([above](#changing-the-terms)).

The worker validates every field (`configOf`), and the app validates
them again (`app/lib/net/remote_config.dart`). An invalid field is
treated as missing, and an unreadable row gives the defaults. The app
keeps the last answer, uses it at the next start, and asks again while
open. It may move the tables only to another relay of ours, never back
to a public one ([one relay, ours](relay.md#one-relay-ours)).

## The service's settings

The service's own numbers, such as how long a licence lasts and each
hourly allowance, live in two rows that are never served
([service settings](../reference/configuration.md#service-settings),
[relay settings](../reference/configuration.md#relay-settings)). A value
that is not a whole number within its bounds keeps its default. The
bounds stop where a setting would open a hole, such as a licence
outliving its subscription or a captured request staying valid for an
hour. Protocol constants (signed statements, code sizes, body limits)
stay in code.

## Watching it run

Monitoring records counts and nothing about anybody, in Workers
Analytics Engine datasets bound as `OH_METRICS`: `open_hearts_api` on
the Pages project's production environment (`infra/cloudflare.mjs`) and
`open_hearts_relay` on the relay (`service/do/wrangler.toml`). Previews
bind none.

- **The worker** (`measure`) writes one line per request: the handler,
  the status, the milliseconds, and a weight. `config` and `health` are
  sampled. An unknown path is recorded as `unknown`.
- **Each relay object** (`tally`) writes a line of counts:
  connections, events, deliveries, subscriptions and each kind of
  refusal. It writes one a minute while it has sockets, and one at once
  when its last socket closes, so a tag whose sockets come and go can
  write more than one a minute. Each line gives the seconds it covers.
  Counts waiting for their minute keep a timer pending, so the object
  is not evicted with them. The columns are in the order `tallied` lists them in
  `service/do/relay.mjs`.

No key, address, tag or location is written. Read the counts with the
Analytics Engine SQL API.

From outside, New Relic (`observability/monitoring.mjs`) pings the
site, the app, `/api/health` and the relay, and tells the operator when
one is down. Its browser agent reports errors, load times and the
service's calls from people's own browsers, on `play.openhearts.game`
only, with no cookies, session replay or session traces. The New Relic
account may hold other apps, so everything of ours is named
`Open Hearts: …`, tagged `app: open-hearts` and gathered in a workload
of its own, and the script reads and writes only what carries that tag
or name.

### The operator's alerts

While there are few subscribers, the operator is emailed about each one
(`service/functions/alerts.mjs`, `alerts` in `config/openhearts.json`):

- **A new subscription**, from the Stripe webhook or the first store
  purchase bound for a subscription. Told once per subscription in a
  while (`SUBSCRIBED_DAYS`), however often the webhook is delivered.
- **A subscriber waiting for a person**: a device that found its pool
  empty and chose to wait for a person rather than play bots
  (`waiting`), so that someone can come and play. Told at most once per
  subscription in a while (`WAITING_MINUTES`).

Whatever the flags say, a failure in the automatic handling of known
images of child sexual abuse is told too (`alertKnownProblem`), at most
once in six hours for each kind, since a legal duty may hang on it
([relay](relay.md#known-images-of-child-sexual-abuse)); and each match
that handling acts on is emailed with what it did.

The mail says which store or pool, the first characters of the
subscription and device, and dates. It never includes an email address
or name. It goes to `alerts@openhearts.game`, which forwards to where
help@ goes (`infra/`). It is sent from the relay worker, which holds the
`EMAIL` binding, through a Household object named `operator-alerts`,
which mails only `@openhearts.game`. A failed alert never fails the
request. Set either flag to `false` and deploy to stop it.

### Reports

A player reports another from the app: holding their badge at the
table, they say what is wrong — the picture, the name or something
else — and can add a note (`app/lib/report.dart`). The `report` handler
emails it to the operator the same way as an alert, but at once and
whatever the flags say, since the app stores require that reports are
answered ([Handle a report from a player](../how-to/handle-a-report.md)).
The mail says both accounts, the table, the name and picture the
reporter saw beside the account's profile now, and the note: what the
operator needs to judge it. Only a subscriber's device can send one,
the same report goes once a day, and an account sends at most
`REPORTS_A_DAY` a day, so that reports cannot bury the operator. A
report that could not be sent is answered 503 and not counted, and the
app says it did not go.

## The relay and the backup jurors

The relay's core ([the relay](relay.md)), `service/do/relay.mjs`, is
plain functions with no Cloudflare or Node imports. It checks
signatures with the app's own `app/web/schnorr.wasm`, passed in
precompiled because a Worker may not compile wasm at runtime. The
Durable Object (`TagRelay`, `service/do/worker.mjs`) hosts it in
production. A plain Node socket server (`service/do/host.mjs`) hosts it
for the tests, so the whole `service/` suite runs against the deployed
relay's code, under the object's own rules or not (`OH_RELAY`).

`service/lib` has a Dart relay with the same behaviour, the default in
the Dart tests and in `dart run bin/service.dart`. The local relays also
accept the simulator's fake signatures; the deployed object accepts only
BIP-340. WebRTC signalling on the relay is sealed to its one recipient
with NIP-44 v2, since an ICE candidate carries an address.

**The backup jurors** ([live play](live-play.md#backup-jurors)). On a
quiet night a table with bot seats calls for jurors on the presence
tag. The presence object passes the call to the `Bench` object
(`service/do/bench.mjs`), at most once in a while (`WAKE_EVERY_MS` in
`service/do/worker.mjs`). The `Bench` object starts a Cloudflare
Container running `service/bin/juror.dart`: the jurors in one process,
with keys derived from `OH_JUROR_SECRET` so that they are the same
across restarts. The jurors go quiet a while after their last call with
nothing to serve (`idleMs` in `juror_duty.dart`), and the object stops
the container. The image is built from the repository on every relay
deploy (`service/bench/build.sh`).

## Deployment

The `Household` object is the relay worker's, built from
`service/functions/household.mjs` and the modules it imports. So a
change to what an account's turn can be asked deploys the relay first,
then the site ([deploy](../how-to/deploy.md)). The other way round, the
new handler asks an object that does not know the question yet, which
answers 400, and the app asks again later.

Secrets are set by hand and checked only by name. Everything else that
is not secret is in `config/openhearts.json`, committed: the service's
public keys (production's, and the one previews have), the TURN key's
id, the Stripe price, and the store and sign-in identifiers. `deploy.sh`
compiles the build's from it and ships the file to the worker, which
reads it beneath the project's settings
(`service/functions/deployment.mjs`): a variable of the same name set on
the project wins, as one set by a test does. A field left null is a
feature left off ([configuration](../reference/configuration.md)).

### Previews

A preview is a deployment of its own, which plays live like production
but reaches nothing of it ([deploy](../how-to/deploy.md#play-live-on-a-preview)).
The Pages project's preview environment binds the previews' store and
bucket, and the households of the preview relay: the same relay worker's
code deployed as `open-hearts-relay-preview` (`[env.preview]` in
`service/do/wrangler.toml`), at its own address, with tags, households
and backup jurors of its own on that store. Both environments say they
are a preview (`OH_DEPLOYMENT`), and each worker then takes the
config as a preview has it (`configFor`): with the service key previews
have, `preview.serviceKey`, and none while there is none, never
production's. Every preview build is made with the same key, and talks
to the preview relay (`deploy.sh`).

A preview runs whatever branch was deployed to it, so its secrets are
its own ([secrets](security-model.md#secrets)). Nobody buys anything on
a preview: the operator invites the people who play there (`oh preview
invite`), each invitation an account on the previews' store that is
nobody's purchase, good for a year, which a device joins with one of
its backup codes. A preview emails nobody: the preview relay has no
mail binding. Nor does it carry profile pictures: it has no pictures
bucket and no checker, and a picture is carried only once it has been
checked against known images ([pictures](#the-accounts-profile)), which
only production does.

### What is defined in code

Cloudflare's and Stripe's settings are defined in `infra/`, and New
Relic's in `observability/`. Scripts check the accounts against them
and change them only when asked
([make the accounts match](../how-to/apply-infrastructure.md)). The
Cloudflare account holds other apps, so the definition keeps to its
own. The two zones are wholly this app's, so a DNS record or rule in
them that is not defined is deleted; elsewhere, only what is named is
read. Some things are checked but never changed from here:

- **Secret values** are checked present by name only, since a script
  holding them is a script that can leak them. A Stripe webhook's
  signing secret is shown once, when the endpoint is made, so a new
  endpoint is made by hand.
- **The relay worker** is defined by `service/do/wrangler.toml` and
  deployed with Wrangler. The script checks the live worker against
  that file, and a difference is fixed by deploying.
- **What Cloudflare makes for a feature**, such as Email Routing's
  records, is read-only through the API, so it is put back by turning
  the feature on again.
- **Keys' permissions**: neither Stripe nor Cloudflare lists them in a
  form worth pinning.
- **Settings only a dashboard can change**, such as Email Sending's
  onboarding and Stripe's branding, receipts, emails about upcoming
  renewals, terms of service URL and statement descriptor.
  Page Rules cannot be read with an account-owned token at all, and none
  are used: the redirects are rules.

A deployment with no keys degrades safely: no service key means live
play is shut, no Stripe means the shop says it is not open, and no TURN
means tables play over the relay.
