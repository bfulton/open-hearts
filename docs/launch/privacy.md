# Launch — privacy

What Open Hearts does with data, read from the code at `f561398`
(1 October 2026) rather than from what it means to do. The public page
made from this is [`site/privacy.html`](../../site/privacy.html). This
file is the working behind it: the inventory, the store answers and the
reasoning for each, where the claim "no data collected" does not hold
and what would make it hold, and what is still the owner's or a
lawyer's to decide.

## The answer first

**Is "Data Not Collected" accurate today?** For the web app with live
play, no. For a phone build of today's code, yes — but only because live
play does not work on phones yet, and it stops being true the day it
does.

- **A phone build of today's code: yes.** On iOS and Android `Uri.base`
  is a `file:` URI with no host. So `appRelays()` falls back to the
  local relay, `ws://127.0.0.1:7447` (`app/lib/net/relays.dart`), and
  `handlerAt()` and `turnEndpoint()` return null (`net/licence.dart`,
  `net/turn.dart`). The app asks no service and reaches no relay. Live
  play cannot be bought there (`canBuyHere` is false off the web) and a
  household code has nowhere to be spent. What is left — solo games,
  the name, the avatar, the records — stays on the phone, and the photo
  picker is local. The label is true for that binary.
- **The web app with live play: no.** A subscriber's display name,
  avatar and photo, their game results and their public key are written
  to relays that other people run, which keep them and let anyone read
  them. Our service keeps their subscription against their key, and
  Stripe holds their email address. That is collection under Apple's
  definition and under Google's (below).
- **Phones, once live play ships as designed: no**, for the same
  reasons — plus a photo's location metadata, unless the bug in
  [A bug to fix before phones publish pictures](#a-bug-to-fix-before-phones-publish-pictures)
  is fixed first.

The other three claims:

- **"No ads"**: true everywhere.
- **"No tracking"**: true in Apple's sense — nothing is linked with
  third-party data for advertising, and nothing goes to a data broker.
  There are no analytics, no crash reporters, no ad identifiers and no
  cookies set by our pages. Two things on the web still need saying:
  the Flutter engine fetches fallback fonts from Google whenever it has
  to draw an emoji, an arrow or a non-Latin name, and anyone can listen
  on the public relays and log who is online and under what name.
- **"No sign-up"**: true. There is no account. A web buyer gives Stripe
  an email address, and live play needs a display name.

## Who is involved

| | What | When |
|---|---|---|
| **The device** | browser storage on the web, app storage on a phone (`shared_preferences`) | always |
| **Other players** | their devices, peer to peer over WebRTC | live play |
| **Jurors** | other people's apps, drawn at random from whoever is online; they hold shares of each hand's escrow and play the bot seats (doc 04). A subscriber's own app is a juror for other tables while it is open | live play |
| **Our service** | the Cloudflare Pages worker `service/functions/worker.mjs` at `/api/…`, with Cloudflare KV (`OH_STORE`) | web: every start (licence check), subscribing, household |
| **Our relays** | `wss://nostr.openhearts.game` (in the list for tables; not running yet — doc 06) and `wss://relay.openhearts.game/{tag}` (presence only; a Durable Object that writes nothing down, `service/do/`) | live play |
| **Public relays** | `wss://relay.damus.io`, `wss://relay.primal.net`, `wss://nos.lol`. Independent operators with their own policies. We have no agreement with any of them | live play; the profile page |
| **Cloudflare** | hosting for the site, the app and the worker; KV; STUN (`stun.cloudflare.com`); TURN (Cloudflare Realtime) | always on the web |
| **Stripe** | Checkout and subscriptions | buying on the web |
| **Google** | `fonts.gstatic.com`, fetched by the Flutter web engine for characters its bundled Roboto lacks | on the web, when such a character is drawn (§2) |
| **Apple, Google (stores)** | not yet | — |

## Inventory

### 1. On the device — every user, every build

Kept in `shared_preferences`: `localStorage` for the site's origin on
the web, the app's own storage on a phone.

| Key | What | Leaves the device | Removed by |
|---|---|---|---|
| `identity_secret` | the device's secret key, 32 random bytes (`identity.dart`). Its public half is the player's identity in every live record | never | clearing the site's data, or deleting the app — which also loses the identity, its rating history and its licence |
| `identity_name` | display name | in live play (§3) | editing it; clearing data |
| `identity_avatar` | icon key, colour index, and a picture: a 64 × 64 JPEG of at most 12,000 bytes | in live play (§3) | the profile page; clearing data |
| `solo_records` | the last 30 solo games: seed, bots, the player's own passes and plays (`record_store.dart`) | only when the player taps **Copy record** | clearing data |
| `pace` | how many cards this device has timed and how long they took (`pace_store.dart`) | the derived seconds-a-card, in live play (§3) | clearing data |
| `game_target`, `game_rated` | the game asked for | the target, in a seating (§3) | clearing data |
| `licence` | the licence: device key, last day, plan, the service's signature | no — the service issued it | dropping the device from its subscription (`subscribe_page.dart`); clearing data |
| `pictures_hidden` | keys of players whose pictures this viewer hid (`pictures.dart`) | never | showing the picture again; clearing data |

**The photo** is picked with the system picker at up to 1024 px, cropped
by the player (`ui/photo_crop.dart`) and shrunk to 64 × 64
(`shrinkPicture`, `profile_page.dart`). Only the shrunk JPEG is kept.
The original is never stored or sent. See the metadata bug below.

There is no in-app control that clears all of this at once.

### 2. Opening the web app — anyone, subscribed or not

- **Requests to the site.** Cloudflare Pages serves the site, the app
  and the worker, and sees each request's IP address, user agent and
  URL. A URL can carry `?room=<code>`, `?claim=<code>` or `?bought=1`.
  Our code logs nothing: there is no `console` call in
  `service/functions/worker.mjs` or `service/do/`. What Cloudflare keeps
  depends on its own policy and on account settings the code cannot
  show — Workers Logs, Logpush, Web Analytics, Bot Fight Mode. The
  owner should check them (see the checklist).
- **Google Fonts, sometimes.** The theme names no font and
  `pubspec.yaml` bundles none, so Flutter's web engine draws text in the
  Roboto it ships with the build (`assets/fonts/fallback/Roboto-Regular.ttf`)
  and, for any character Roboto lacks, fetches a Noto fallback font from
  `fonts.gstatic.com` — `fontFallbackBaseUrl` is left at its default.
  `--no-web-resources-cdn` in `deploy.sh` moves CanvasKit onto our own
  origin; it does not move the fallbacks. Measured on a release build
  made with this repo's flags (Flutter on Dart 3.13.2, headless
  Chromium): loading the front door and opening the profile page made
  no request off our origin; typing a name with an emoji and an arrow in it
  fetched Noto Color Emoji, Noto Sans Symbols and Noto Sans SC/TC from
  `fonts.gstatic.com` at once. The app's own strings need a fallback in
  two places, both in live play: the rated score sheet's
  "Rating 1500 → 1516" (`ui/overlays.dart`) and the stuck-deal note's
  "2♣" (`live/live_page.dart`). So Google is reached when a rated game
  moves a live player's rating, and whenever a name on screen holds an
  emoji or a script other than Latin, Greek or Cyrillic. Google then receives the
  visitor's IP address, user agent and, under the site's
  `Referrer-Policy: strict-origin-when-cross-origin`, our origin. The
  fix is in the conflicts list.
- **The licence check.** On every start `main.dart` posts the device's
  public key to `/api/licence`. For a key with no subscription the
  worker reads one KV row, writes nothing and answers 402: nothing is
  kept. For a subscriber, see §4.
- **The update check** fetches `build-info.json` from our own origin and
  sends nothing.
- **The profile page**, opened by anyone on the web, calls
  `Standing.load`: a connection to every relay in the build's list,
  subscribed to the `results` tag. Nothing is published, but the
  subscription carries a filter naming this device's public key
  (`RelayTransport` always asks for signalling addressed to itself), and
  every relay sees the IP address. For someone who never subscribes,
  this is their only contact with third-party relays.

### 3. Live play — subscribers; the web today

"Every relay" means the build's whole list, public relays included.
Kinds 20000–29999 are ephemeral: by NIP-01 a relay forwards them to
whoever is subscribed at that moment and keeps nothing. Kind 4244 is a
regular kind, and relays store it.

| # | What | When | Where | Kind | Who can read it | Kept |
|---|---|---|---|---|---|---|
| 1 | **Presence**: `{"kind":"here","status":"online"\|"seated"}`, signed by the device key; `gone` when the app is backgrounded (`presence_relay.dart`, `duty.dart`) | every 5 s while the app is open, licensed and able to deal | every relay, and `relay.openhearts.game/online` first | 24246, ephemeral | anyone subscribed to the tag `online` | not by the relays; anyone listening can record it |
| 2 | **Pool beat**: `{"kind":"wait", name, rating, pace, since, avatar}` — `avatar` is icon and colour (`matching.dart`) | every 2 s while waiting | every relay | 24245, ephemeral | anyone subscribed to the pool's tag (`queue:rated`, `queue:unrated`, `…:100`) | as row 1 |
| 3 | **Room beat**: `{"kind":"here", name, seed, since, policy, avatar}` (`room.dart`) | every 2 s in a friends' room | every relay | 24245, ephemeral | anyone subscribed to the room code | as row 1 |
| 4 | **Picture**: `{"kind":"picture","jpeg":…}` | once on entering a pool or a room, if the player has one | every relay | 4244, **stored** | anyone — a filter on the kind alone returns it; the tag is no barrier | as long as each relay chooses |
| 5 | **Seating**: `match` (pool) or `start` (room) — table id, seed, target, rated, and for each person their key, display name, icon and colour | once per table, by the round's host or the room's leader | every relay | 4244, **stored** | anyone | as long as each relay chooses |
| 6 | **Table events**: passes, plays, heartbeats (with the relays the sender reads), leaves, boots, jury business, the deal's cryptography, and the audit that opens every hand at its end | throughout a game | WebRTC data channels (DTLS) to the other people and the hand's jurors; a relay only while someone has no channel open (`mesh_transport.dart`) | 24242, ephemeral, tagged with the table id | the table and its jurors; on the relay lane, anyone subscribed to that table id while it plays | not stored |
| 7 | **Signalling**: offers, answers, ICE candidates | when a channel is set up | every relay | 24243, ephemeral, sealed with NIP-44 to the recipient | the recipient only — but it carries IP addresses, so the recipient learns yours | not stored |
| 8 | **Summonses and calls** for jurors: the table's seats (keys and bot ids), the hand, the jury | when a table draws a jury | every relay | 24246, ephemeral | anyone subscribed to `online` | not stored |
| 9 | **Result**: `{"kind":"result", table, rated, seats: [{key or bot, total, fromStart, left}]}` (`results.dart`) | the end of every live game, **rated or unrated** (`home_page.dart`, `onResult`), retried until a relay takes it | every relay | 4244, **stored**, tag `results` | anyone | meant to be permanent: every rating is folded from all of them |
| 10 | **ICE servers**: `POST /api/turn {key}`; STUN at `stun.cloudflare.com` | on connecting | our worker; Cloudflare | — | — | the worker keeps nothing; Cloudflare's STUN and TURN see IP addresses, and TURN carries already-encrypted bytes |

What follows:

- **Rows 5 and 9 together are a public game history.** Results carry
  keys and not names; seatings carry both. Anyone can see when a named
  player played, against whom, how they scored, whether they left, and
  the rating that comes out of it.
- **A "private" friends' room only keeps strangers from sitting down.**
  Its start event and pictures are stored on public relays like any
  other, readable by anyone who asks for the kind.
- **IP addresses** reach every relay, Cloudflare, every person at the
  table and every juror. Jurors are strangers — and while a subscriber's
  app is open it is itself a juror, dialled by the people at other
  tables. Browsers hide local network addresses in ICE candidates behind
  mDNS names; the native WebRTC library may not, so on a phone a peer
  could learn a local address too. Check when live play reaches phones.
- **Pace** is measured by the device of its own turns and stated in
  every pool beat (row 2). It is in no result and no relay stores it.
  Two code comments overstate that — `stats.dart` ("Never on a relay …
  nobody else is told") and `home_page.dart` ("goes on the device and
  nowhere else") — and the profile page says only that you are seated
  with players at a similar pace.
- **Nothing in the app says that a name or a picture becomes public and
  is kept by other people.** The profile page asks for "Your name" and
  offers "Use a photo".
- **The picture check** described in doc 04 is not shipped:
  `Pictures` runs with `check: null`, so every picture shows unless the
  viewer hides it.

### 4. Subscribing — the web

- `POST /api/checkout {key, back, cancelled}`. The worker opens a
  Stripe Checkout session with the device key in three places: the
  session's metadata, its `client_reference_id`, and the subscription's
  metadata.
- **On Stripe's page** (`checkout.stripe.com`, under Stripe's own
  privacy policy and cookies): email address, card details, cardholder
  name, billing country and postcode as Stripe's settings ask, and
  Stripe's own fraud signals.
- **What the owner can see in the Stripe Dashboard**: email, name,
  billing country, card brand and last four digits, payment history, and
  the device key in the metadata. Never a full card number.
- **The webhook** (`/api/stripe`, signature checked first) writes to KV:
  - `SUB#<Stripe subscription id>|META` — source, latest invoice id,
    renewal day, cancellation day
  - `SUB#<id>|DEVICE#<key>` — the day the device was bound
  - `SUB#<id>|CUSTOMER` — the Stripe customer id, so a device on the
    subscription can open Stripe's billing portal
  - `KEY#<key>|ENTITLEMENT` — subscription id, licensed-until day, the
    day it was written
- **`POST /api/manage {key, back}`** opens a Stripe billing portal
  session for that customer (`billing.stripe.com`, Stripe's page, where
  the subscriber sees their email, card and receipts). Any device bound
  to the subscription may open it.
- **Only a household code's rows expire** (an hour after the code is
  made). An ended subscription is dated down, not deleted.

So KV joins a device key to a Stripe subscription, and Stripe joins the
subscription to an email address. With §3, the owner can connect a
paying web player's email to their public name and game history. Nobody
else can.

### 5. Other devices on one subscription

- `/api/ticket {key}` writes `TICKET#<code>|META` — subscription,
  expiry (ten minutes), `used_at`, `made_by` (the key that asked).
- `/api/claim {key, ticket}` adds `used_by` and binds the new device as
  in §4. The code travels in a link (`?claim=`), by camera or by share
  sheet.
- Ticket rows are never deleted, though a spent or expired code is
  worth nothing.
- `/api/devices {key, drop?}` lists the keys on the subscription and the
  days they were bound, to any device on it; `drop` removes a device's
  binding and entitlement rows.

### 6. Sign-in — built in the service, not in the app

`/api/attest` and `/api/supersede` would store
`LOGIN#<provider>#<HMAC of the provider's subject>` → key,
`KEY#<key>|META` (provider, day attested) and `KEY#<key>|SUPERSEDES`.
Nothing reaches them yet: no audience is configured and the app has no
flow. When it ships, Apple or Google learns that the person signed in
to Open Hearts, and we store an HMAC of their identifier, never the
identifier.

### 7. Telling us what's broken — only when the player sends it

The menu's "Tell us what's broken" (`app/lib/feedback_page.dart`) sends
nothing by itself. What would go is on the page before it goes: the
player's own words, the build tag and day, the platform, the app's
language, the screen's size in points, and — from a solo table, only if
the player ticks it — the game's record (seed and their own passes and
plays). Send opens the destination with the report filled in: by
default a new issue on the project's public GitHub, which the page says
anyone can read; the operator can point it at a form or a mail address
instead with the remote config's `feedback` (doc 06). Off the web the
report is copied for the player to paste. So it is user-initiated,
optional, and shown in full — but if it goes to GitHub it is public,
and if it goes to a form or mail we hold what was sent: the store
answers should then add **User Content → Customer Support** (Apple) and
**App activity → Other user-generated content** (Google), optional and
not linked unless the player signs it.

### 8. Not collected anywhere

No analytics, crash reporting, advertising identifiers, fingerprinting,
cookies from our pages (Stripe sets its own, on its own domain),
location (the metadata bug below is fixed), contacts, device model, chat, or
email address held by us. The worker and the relay object log nothing;
with the operator's metrics turned on (doc 06, "Watching it run") they
write counts — a handler's name, its status and how long it took; a
minute's connections and events per relay object — and nothing about
who: no key, no address, no tag, no location.
The counters doc 06 describes (`COUNTER#…`) are not built.

## A bug that was fixed before phones publish pictures

**A photo's location can ride along in the avatar.** On Android,
`image_picker`'s `ExifDataCopier` copies the GPS tags into the resized
image it returns (`image_picker_android` 0.8.13+23). Then
`img.decodeImage` reads the EXIF into the image, `copyCrop` and
`copyResize` clone it, and `encodeJpg` writes it back out (`image`
4.10.0). So the 64 × 64 avatar can carry the latitude and longitude
where the original was taken — and in live play it is published to
public relays and kept. The iOS picker keeps metadata the same way
(`FLTImagePickerMetaDataUtil`), so iOS is probably the same. The web is
spared: `image_picker_for_web` redraws through a canvas, which drops
EXIF.

The image half was run: the same calls `shrinkPicture` makes —
`decodeImage`, `copyCrop`, `copyResize` to 64, `encodeJpg` at 82 — on a
JPEG carrying GPS latitude and longitude gave an 827-byte avatar that
still carried all four GPS tags, and none once `exif` was cleared
(`image` 4.10.0, Dart 3.13.2). The picker half — that Android's and
iOS's pickers hand the tags over in the first place — is read from
their source, not run on a device. **Fixed:** `shrinkPicture` now
clears the metadata before encoding (`square.exif = ExifData()`), and
`app/test/avatar_test.dart` shrinks a JPEG tagged with a position, both
whole and cropped, and checks that nothing of its EXIF comes out the
other side. The same clearing keeps a phone's embedded thumbnail from
pushing a picture over the 12,000-byte cap.

## Retention and deletion

| Where | How long | How it is deleted today |
|---|---|---|
| The device | until removed | clear the site's data in the browser, or delete the app; the profile page edits name and picture |
| Public relays — pictures, seatings, results | each operator's choice; often indefinite. Anyone can copy a signed event to another relay | not by us. The app sends no NIP-09 deletion requests (kind 5), and a relay need not honour one |
| Ephemeral events — presence, beats, table events, signalling | not stored by relays | — (anyone listening could have recorded them) |
| Our relay object | nothing written down | — |
| KV — subscriptions, devices, tickets | indefinitely | by hand, on request. There is no self-service delete, and a requester has to say which key is theirs, which the app shows only six characters of |
| Stripe | Stripe's policy and the law on payment records | the owner can delete a customer in the Dashboard; Stripe keeps what it must |
| Cloudflare request logs | Cloudflare's policy and the account's settings | — |
| Google Fonts requests | Google's policy | — |

## Store answers

### Apple App Store — App Privacy

The rules that decide this (developer.apple.com/app-store/app-privacy-details,
read 1 October 2026):

- *"'Collect' refers to transmitting data off the device in a way that
  allows you and/or your third-party partners to access it for a period
  longer than what is necessary to service the transmitted request in
  real time."*
- An IP address or token sent on a call and not retained need not be
  disclosed.
- *"You are not responsible for disclosing data collected by Apple."*
- "Personal Information" and "Personal Data" under privacy law are
  linked to the user. A display name, a photo and a key that signs
  everything a player does are personal data.
- Optional disclosure needs **all four** of: not used for tracking; not
  used for advertising, marketing or other purposes; collected *"only in
  infrequent cases that are not part of your app's primary
  functionality, and which are optional"*; and *"provided by the user in
  your app's interface … the user's name or account name is prominently
  displayed in the submission form … and the user affirmatively chooses
  to provide the data for collection each time."*

**A store build of today's code (solo only): Data Not Collected.** True
as long as the conditions in [The answer first](#the-answer-first)
hold: no service and no relay is reachable from a native build. Check
again on any build that changes `appRelays`, `handlerAt`,
`turnEndpoint` or `canBuyHere`.

**Live play on iPhone, as designed** — Data Linked to You, none used to
track:

| Data type | Purpose | Why |
|---|---|---|
| Identifiers → **User ID** | App Functionality | the public key (an "assigned user ID" every public record carries) and the display name (a "screen name"), published in stored seatings |
| User Content → **Photos or Videos** | App Functionality | the avatar picture, when the player chooses one, published as a stored event |
| User Content → **Gameplay Content** | App Functionality | results (stored, public) and seatings — "multiplayer matching" |
| Purchases → **Purchase History** | App Functionality | the service keeps the subscription against the device key (doc 06, entitle). Not needed if store entitlements are checked on the device only (conflict 5) |
| Location → **Precise Location** | — | not collected: the metadata bug is fixed (avatar_test.dart) |

Not declared, and why:

- **Contact Info → Name.** Apple's is "first or last name"; a display
  name is a screen name, which is User ID. People do type real names
  into a name field, so tick Name as well if you would rather be safe.
- **Identifiers → Device ID.** The key is made per device, but it is the
  player's identity, so User ID is the closer fit. Ticking both does no
  harm.
- **Usage Data.** Presence and pace are ephemeral: neither we nor the
  relays keep them.
- **Diagnostics.** None are gathered.
- **Coarse Location.** IP addresses are not retained by us and not used
  to place anyone. Confirm Cloudflare's logging settings.
- **Contact Info → Email.** Stripe, on the web only; not part of the
  iOS app.

The optional-disclosure exception does not help: live play's name and
picture fail its third criterion (they are part of the app's main
multiplayer function, not an infrequent case) and its fourth (they are
sent automatically every time, not submitted through a form).

**Data Used to Track You: none.** No App Tracking Transparency prompt is
needed, and none should be added. Keep it that way for Apple Ads too:
no AdServices attribution call (store-listing.md).

**When sign-in ships:** the service stores an HMAC of the provider's
subject against the device key. That is still User ID; nothing new
unless an email address is taken, and none is.

### Google Play — Data safety

The rules (support.google.com/googleplay/android-developer/answer/10787469,
read 1 October 2026):

- Collection is *"transmitting data from your app off a user's
  device."* Data processed only on the device, or sent end-to-end
  encrypted and readable by nobody but sender and recipient, is not
  collected. Data processed ephemerally is still entered in the form,
  marked as such.
- Sharing is transferring user data to a third party. Not sharing:
  transfers to service providers working on our behalf, for legal
  reasons, on a user-initiated action the user reasonably expects to
  share, after prominent in-app disclosure and consent, or of anonymous
  data.
- Google's **Name** explicitly includes a nickname.

**A store build of today's code: "No" to collecting or sharing any
required data type.** The privacy policy URL is still required.

**Live play on Android, as designed:**

| Category → type | Collected | Shared | Ephemeral | Optional | Purpose |
|---|---|---|---|---|---|
| Personal info → **Name** (display name) | yes | yes | no | yes — only live play asks for it | App functionality |
| Personal info → **User IDs** (public key) | yes | yes | no | yes | App functionality |
| Photos and videos → **Photos** | yes | yes | no | yes | App functionality |
| App activity → **Other actions** (gameplay: results, seatings, the rating and pace stated in matching) | yes | yes | no | yes | App functionality |
| Financial info → **Purchase history** | yes, once Play Billing lands and the service records it | no — Google is the processor, Cloudflare our service provider | no | yes | App functionality, Account management |

Not declared: Location (the metadata bug is fixed), App info and
performance (no crash logs), Messages (no chat), Email address. As with
Apple, the key could also go under Device or other IDs.

**Why "shared".** The public relays are not our service providers:
there is no contract, and they keep what they are given for their own
users. The user-initiated exception — the user "reasonably expects the
data to be shared" — fits the people at the table, but is weak for
permanent copies on strangers' servers, all the more while the app does
not say so. Declare it shared. Once the app shows a prominent notice
and asks before live play, the disclosure-and-consent exception may
apply; even then "shared" is the safer answer.

**Security practices.**

- *Data is encrypted in transit*: yes — HTTPS, `wss://` in every
  production relay URL, DTLS on the data channels, NIP-44 on
  signalling. The `ws://` local relay is never in a release build.
- *You can request that data be deleted*: answer yes only once there is
  a working way to do it (open decisions), and say in the policy that
  the public relays are out of reach.
- *Account deletion*: Google requires an in-app and a web route to
  delete an account when an app lets people create one. A key with a
  public name is closer to an account than not, and with Play Billing
  the service keeps a subscription per key. Have a deletion route ready
  before live play ships on Android.

## Conflicts with "no data collected"

Each with where it is, what would make the claim true, and what that
costs.

1. **Names, icons and colours in stored seatings** — `match` in
   `matching.dart` (`_hostRound`), `start` in `room.dart`. *Change:* make
   seatings ephemeral and have the host or leader repeat them for a few
   seconds (a pool already reads only the last minute), or seal each
   seating to the seated keys with NIP-44, as signalling is. *Cost:* a
   friend arriving late to a room depends on a leader still being there
   to repeat it, rather than on the relay's history.
2. **Pictures as stored events** — `room.dart`, `matching.dart`.
   *Change:* send a picture over the data channel once the table is up,
   or as an ephemeral event sealed to each seat. *Cost:* a picture
   arrives a moment after the table rather than in the lobby.
3. **Results, stored and public** — `results.dart`, `Standing.publish`.
   This is the rating system. *Options:* (a) keep it, and declare
   Gameplay Content and User ID; (b) ephemeral results, each device
   folding only the games it saw, which makes ratings local and partial;
   (c) results on our relay only, deleted after a set time — still
   collected, by us, but not by third parties. "Data Not Collected" and a
   public rating ledger cannot both be true.
4. **Unrated games publish results too** — `home_page.dart`, `onResult`
   publishes whatever `spec.rated` says. *Change:* publish only rated
   results. Cheap, and an unrated game then leaves nothing behind.
5. **A subscription row per device key** — `worker.mjs` (`record`,
   `claimWith`, `entitlementOf`). *Change, on phones:* check the StoreKit
   2 or Play Billing entitlement on the device and never send it to the
   service. The licence is only ever checked by the device that holds it
   — nothing in `packages/table` checks another device's — so this is
   possible. *Cost:* no five-device household across platforms through
   our service; each store restores its own purchases. On the web,
   Stripe makes this collection unavoidable, but the web is not under
   the store labels.
6. **Presence, pool and room beats on public relays** —
   `presence_relay.dart`, `matching.dart`, `room.dart`. Ephemeral, so
   not "collected" by Apple's letter, but anyone can record them.
   *Change:* carry them on our own relays only, once those are reliable
   (presence already prefers `relay.openhearts.game`). *Cost:* when ours
   are down, nobody is online.
7. **IP addresses reach peers and jurors** — WebRTC. Not collection in
   either store's sense, but personal data shown to strangers.
   *Change:* `iceTransportPolicy: 'relay'` forces TURN and hides
   addresses from peers. *Cost:* TURN traffic for every table, on our
   bill. At the least, say so — the policy does.
8. **Google Fonts fallbacks on the web** — the engine's default
   `fontFallbackBaseUrl`. Not a store-label item, but readers of "no
   tracking" will expect it gone, and a German court has found loading
   Google Fonts from Google's servers unlawful without consent
   (LG München I, 20 January 2022, 3 O 17493/20). *Change:* set
   `fontFallbackBaseUrl` to our own origin in a custom
   `flutter_bootstrap.js` and mirror the Noto fallbacks there (all of
   them is about 22 MB; only the files actually requested are served),
   or bundle one font covering the scripts and emoji names will use. The
   app's own two characters — `→` and `♣` — could simply be drawn
   differently, as the suit pips already are. *Cost:* storage and a
   step in `deploy.sh`.
9. **The profile page reaches public relays for non-subscribers** —
   `home_page.dart`, `_statsOnThisDevice` passes `_relays` whenever the
   app is online. *Change:* pass them only when live play is open.
   Cheap.
10. **KV rows kept for ever** — `ticketFor` and the subscription rows.
    *Change:* an `expirationTtl` on ticket rows (a day), and delete a
    subscription's rows a stated time after it ends.
11. **Photo metadata** — above. *Change:* clear it before encoding.
12. **The words** — the pace comments, and a profile page that says
    nothing about who will see a name or a picture. *Change:* say,
    where the name is asked for, that the name and picture are public
    at live tables and kept by relays that other people run.

## Gaps the stores will ask about

- **No privacy policy link in the app.** Apple (guideline 5.1.1(i)) and
  Google's User Data policy both want one inside the app, not only in
  the listing. The About page is the natural place.
- **User-generated content (Apple guideline 1.2).** Apps with UGC need a
  way to filter objectionable material, to report it, to block abusive
  users, and published contact information. Live play has free-text
  names and photos. What exists is hiding a picture on one's own device;
  there is no report, no block, and no filter (the model is not
  shipped). Live play on iOS will probably need report and block at
  least.
- **No self-service deletion.** A `/api/forget` signed by the device key
  could delete that key's KV rows, and the app could send NIP-09
  deletion requests for its own stored events, which relays may honour.
- **No contact email.** A postal address and a phone number are
  published (`site/privacy.html`, Contact; `site/support.html`); there is
  still no email address, which Play Console requires. See below.

## For the owner and a lawyer to check

- **Who the controller is.** A person or a company; legal name; postal
  address. The page says "the people who maintain the Open Hearts
  project", which will not satisfy GDPR Article 13.
- **A contact address — partly decided.** The page now gives a postal
  address and a phone number for privacy requests: Open Hearts, 6650
  Rivers Ave, Ste 105, PMB #804106, North Charleston, SC 29406, USA;
  +1 (843) 827-0686. That is a mailbox service's address, which may not
  do as the controller's establishment for GDPR Article 13. There is
  still **no email address** (`[CONTACT EMAIL]` in outreach.md stays
  open). GitHub issues (<https://github.com/bfulton/open-hearts/issues>)
  stay the place for bugs, and the page says to put nothing private in
  one. A requester still has no way to show which key is theirs: the
  page asks for the name they play under and, for a web subscriber, the
  email they paid with, and the app does not show the key.
- **Jurisdiction and governing law**, where the controller is
  established, and whether an EU or UK representative (GDPR Art. 27) is
  needed.
- **Lawful bases**: contract (live play, a subscription), legitimate
  interests (security, abuse), legal obligation (payment records), and
  consent where needed (Google Fonts, if kept).
- **Publishing personal data to third-party relays by design**:
  transparency, the erasure requests that cannot be carried out there
  (Art. 17(2), "reasonable steps"), and transfers to operators in
  unknown countries.
- **Processor terms**: Cloudflare (Pages, KV, Realtime TURN — its DPA is
  part of its terms) and Stripe (its DPA; Stripe is an independent
  controller for some of its own processing).
- **Cloudflare settings**: Workers Logs, Logpush, Web Analytics and any
  bot-management cookies — off, or disclosed.
- **Retention periods to state**: KV rows after a subscription ends;
  Stripe's payment records.
- **Children**: no age gate, and public names and photos at live tables.
  The page says the game is not made for under-13s. Check COPPA (general
  audience?), the GDPR's age of digital consent (13–16 by member state),
  and make the stores' target-audience and age-rating answers match.
- **Terms of service**: drafted at `site/terms.html` (served at
  `/terms`), not yet reviewed by a lawyer. It defers to Apple's Standard
  EULA for App Store purchases and covers web purchases: a year at
  $5.99, automatic renewal, cancelling (on the web, in Stripe's billing
  portal from Manage subscription, or by mail or phone with no device
  left), refunds, conduct, MIT against the
  service, no warranty, a liability cap, South Carolina law. To check:
  automatic-renewal disclosures (California and others) at checkout and
  a reminder before renewal, which we cannot send without an email
  address; the EU 14-day withdrawal right for digital content and its
  waiver at checkout; the refund promises it makes (unused part refunded
  if we stop renewing a device without good reason).
- **CCPA/CPRA**: probably under the thresholds. CalOPPA requires a posted
  policy, which this is once published.
- **ePrivacy**: browser storage used only for what the player asked for
  should need no consent banner. Confirm.

## Store submission checks this audit turned up

Not privacy, but found on the way:

- **iOS purpose strings.** `flutter_webrtc` links camera and microphone
  capture. App Store Connect can refuse a binary that links those APIs
  without `NSCameraUsageDescription` and `NSMicrophoneUsageDescription`
  (ITMS-90683), even though the app never asks for either. Likely, not
  verified.
- **iOS privacy manifest.** `shared_preferences` and `image_picker` ship
  their own `PrivacyInfo.xcprivacy`; the app has none of its own. Check
  whether `flutter_webrtc` needs one.
- **Android launcher label.** `AndroidManifest.xml` has
  `android:label="open_hearts"`; it should read "Open Hearts". iOS's
  `CFBundleDisplayName` already does.
- **Live play on a store build.** The subscribe page on a phone says
  live play "is bought on the web". Outside the US storefront that is
  steering under App Review guideline 3.1.1. See store-listing.md.
