# Launch — outreach

What goes out after launch, beyond the store pages: an App Store
featuring nomination, three press pitches, a kit for senior centres,
and two community posts. The printable handout is also
[`senior-center-handout.html`](senior-center-handout.html), and the two
must say the same thing.

Every count in this file is measured, not typed, by the same tool as
the store listing: `node docs/launch/count-fields.mjs` rewrites them
after an edit, and `--check` fails if one is stale or a field is over.
A limit marked *set here* is ours, to keep a pitch short; the others are
the platform's.

## Placeholders

Nothing below with a bracketed name in capitals is ready to send until
that name is filled. Values are as found on 1 October 2026.

| Placeholder | What goes there | Today |
|---|---|---|
| `[PLAY URL]` | The address people open to play | Meant to be `https://openhearts.game/play`; the domain is not attached and does not resolve. Production, `open-hearts.pages.dev`, has no deployment ("Nothing is here yet"). Only `https://dev.open-hearts.pages.dev/play` answers, and it is a dev build from 29 September (`c4055dc`), from before the five languages and Read aloud |
| `[SITE URL]` | The site | Meant to be `https://openhearts.game/` |
| `[PRIVACY URL]` | The privacy policy | Meant to be `https://openhearts.game/privacy` (`site/privacy.html`) |
| `[SOURCE URL]` | The public repository | `https://github.com/bfulton/open-hearts`, which is **private** today |
| `[APP STORE LINK]` | The App Store page | Not submitted |
| `[GOOGLE PLAY LINK]` | The Google Play page | Not submitted |
| `[APPLE ID]` | The app's Apple ID, from App Store Connect | Not created |
| `[LAUNCH DATE]` | The App Store publish date, `YYYY-MM-DD`, at least three weeks after the nomination goes in | Not set |
| `[COUNTRIES]` | Three-letter ISO codes for the nomination | Not decided; store-listing.md plans the United States first |
| `[PRESS KIT URL]` | Screenshots and the icon, in one place | None. store-listing.md lists the screenshots to take |
| `[TESTFLIGHT LINK]` | A public TestFlight link, optional | None |
| `[CONTACT EMAIL]` | An address the press can write to | None exists; privacy.md leaves it to the owner |
| `[HELP CONTACT]` | Where a player gets help in private: an email address or a phone number | None. In the app, "Tell us what's broken" opens a new GitHub issue, which is public, on a repository that is private |
| `[YOUR NAME]` | Who signs | The owner's to decide (privacy.md: the controller's name is undecided) |
| `[ACTIVITY DIRECTOR NAME]` | Mail merge, one letter each | — |

## Before any of this goes out

Found while writing this; none of them is a copy change, and each one
blocks some of the copy.

1. **The repository is private.** Every "open source" line, every
   `[SOURCE URL]`, and the app's own "Tell us what's broken", which
   opens an issue there, wait on it being made public.
2. **Nothing is on production.** Deploy the launch build and attach
   `openhearts.game` before printing a handout or sending a pitch. The
   dev alias is an older build: someone sent there today would get
   English only, and none of the Read aloud work.
3. **Live play on production is unconfirmed.** The repo cannot show
   whether the Stripe keys, the service key and the relays are set
   (README, "Developing"; security-review.md, "What the owner has to
   do"). Until someone buys a subscription on production and plays a
   live table, cut every line about live play, the deal and ratings:
   the open-source pitch, the first section of the Reddit post, and
   the live-play line of the senior pitch and the forum post. The
   handout and the cover letter keep theirs, since the front door
   shows the price whether or not the shop is open.
4. **There is no private way to ask for help.** The handout and the
   cover letter need `[HELP CONTACT]`. An older person who gets stuck
   will not open a GitHub issue, and should not post private details
   in one.
5. **Screen readers have not been tried on a device.** The Read aloud
   pass (doc 05) was a hand played through headless Chromium's
   accessibility tree, not VoiceOver on an iPhone, TalkBack on Android
   or a desktop screen reader. On the web, Flutter grows that tree only
   after the reader activates a hidden button labelled "Enable
   accessibility". The app does not turn it on itself; `main.dart`
   does so only for the test suites. Check VoiceOver on an iPhone
   before the AppleVis pitch goes out or the nomination mentions it.
6. **Check the handout's zoom steps on real phones.** The web engine
   follows browser zoom and the browser's text size: it reads the
   page's root font size into the app's text scale
   (`findBrowserTextScaleFactor`, Flutter 3.47.2 web engine). That was
   read from the source, not tried on a phone. Try "Zoom" in Safari on
   a current iPhone and in Chrome on an Android phone, against the
   production build, and change the handout's wording to match the
   menus you find.
7. **iOS does not declare its languages.** `app/ios/Runner/Info.plist`
   has no `CFBundleLocalizations`. Without it the App Store is likely
   to show the app as English only, and the nomination's Localization
   field would not match the product page. Add `en`, `es`, `pt-BR`,
   `de` and `fr` (an `app/` change, not made here).
8. **Two pages a journalist will read say less than is true.**
   store-listing.md still says "The app itself is in English only, and
   each description says so", and the four translated descriptions end
   by saying the app is in English. Both stopped being true with
   `43a8bee`. `site/index.html`, "Where it is going", still says that
   today it is you against three bots in a browser.

## What the copy may claim

The phones' first release is solo only (store-listing.md, "What the
copy may claim"). Live play, ratings and the verifiable deal are on
the web. Every piece below says which one it means.

| Claim | Web | Phones, first release | Where it is |
|---|---|---|---|
| Hearts against three bots, free for good | yes | yes | README roadmap 1; `aloneIsFree` |
| No ads | yes | yes | privacy.md |
| No account, no sign-up | yes. A web buyer gives Stripe an email address, and live play needs a display name | yes | privacy.md |
| To play alone, it never asks for a name, an email or a card | yes | yes | *Play solo* goes straight to the table (`home_page.dart`) |
| Data Not Collected | **no**: never say it of the web | yes, for this build | privacy.md, "The answer first" |
| "No tracking" | only as privacy.md qualifies it: no analytics, no ad identifiers, no cookies of ours; Google fonts fetched for emoji and non-Latin names; public relays at live tables | yes | privacy.md |
| Tells you which rule stopped a card | yes | yes | `refusalFor` |
| Forty named bots with temperaments, each measured | yes | yes | `persona.dart`, doc 04 |
| Bots rated like people, seated near your rating | live play only | no | doc 04, "Ratings" |
| A deal nobody at the table can rig | live tables only | no | doc 03, "As built" |
| A solo game replays from one line of text | yes | yes | doc 03, "Where the randomness comes from" |
| Live play, $2.99 a year | yes, through Stripe | no: store billing is not built | doc 06 |
| Five languages: English, Spanish, Brazilian Portuguese, German, French | yes | yes, once `CFBundleLocalizations` is added on iOS | README, "Languages". The translations are a first pass |
| Screen readers | yes: names, seats, announcements. After "Enable accessibility" | probably, untested | doc 05, "Read aloud" |
| Bigger text | browser zoom and the browser's text size | the system text size | doc 05; the Flutter web engine |
| Honours reduce motion | yes | yes | doc 05 |
| Phones, tablets, foldables, either way up | yes | yes | doc 05. The foldable is tested in widget tests, not on a device |
| Works offline | not claimed | yes | store-listing.md |
| Open source, MIT | once the repository is public | same | `LICENSE` |

Never claimed: that the cryptography is audited (the reference crate is
research code, unaudited: doc 03); that anything stops two players
sharing hands on a phone call; "the best Hearts app"; a team size; a
number of players or downloads.

## 1. App Store featuring nomination

**The form.** App Store Connect → the app → Featuring Nominations, read
from Apple's help pages on 1 October 2026 ("Nominate your app for
featuring", and the bulk-upload "Nominations template"). The form asks
for a name, a type, a description, a publish date or range, related
apps, platforms, countries or regions, localizations, In-App Events,
up to five supplemental URLs, and "Helpful Details", where Apple asks
about accessibility and inclusivity in so many words. The limits used
below (60, 1,000 and 500 characters) are from the template page; the
form's own help page states none. If the form shows a different limit,
the form wins. Apple asks for at least three weeks' notice.

**Describe only the iOS build.** The first release is solo, so the
nomination says nothing of live play, ratings or the deal. Nor does
it mention buying on the web: App Review treats pointing iOS users at
an outside purchase as steering (store-listing.md).

| Field | Value |
|---|---|
| Related Apps | `[APPLE ID]` |
| Nomination Type | App Launch |
| Publish Date | `[LAUNCH DATE]` |
| Platforms | iOS (iPhone), iOS (iPad) |
| Relevant Countries or Regions | `[COUNTRIES]` |
| Do you plan to launch in certain markets first? | No, unless `[COUNTRIES]` says otherwise |
| Localization | en-US, es-MX, pt-BR, de-DE, fr-FR, and es-ES if the listing is localized there too. Pre-filled from the listing; check it matches item 7 above |
| In-App Events | none |
| Does this app or game include a pre-order? | No |
| Supplemental Materials (up to 5) | `[PRESS KIT URL]`, `[PLAY URL]`, `[SOURCE URL]`, `[PRIVACY URL]`, `[TESTFLIGHT LINK]` |

**Nomination Name**
<!-- limit=60 unit=chars -->
```text
Open Hearts: Hearts with no ads, for iPhone and iPad
```
Count: 52 of 60 characters

**Nomination Description**
<!-- limit=1000 unit=chars -->
```text
Open Hearts is the card game Hearts for iPhone and iPad with nothing in the way: no ads, no account, nothing to buy, no data collected, and it works offline.

You play three bots with names and temperaments. Romeo can't hold on to the queen; Don Juan runs at the moon with a hand nobody else would try. There are forty of them, each measured against the rest so that none plays badly. Tap a card you can't play and the game says which rule stopped you, which makes it a gentle way to learn Hearts or to come back to it.

The table is laid out from the space it is given rather than from a list of devices, so iPhone upright or on its side, iPad, iPhone Duo open or closed, and Split View each get a table made for them, and turning or unfolding mid-hand keeps the game. It speaks English, Spanish, Brazilian Portuguese, German and French, follows Reduce Motion and the system text size, and is open source under the MIT license.
```
Count: 928 of 1000 characters

**Helpful Details**
<!-- limit=500 unit=chars -->
```text
Before launch we played a whole hand of the web build using only its accessibility tree, every move chosen from what it said. That pass added where each player sits, spoken trick results and turns, and scores read as sentences; the two gaps still open are written up in our docs. The rules engine and the bots are public code you can read and argue with. Playing alone is free for good, and this release has no in-app purchases.
```
Count: 428 of 500 characters

The description's last paragraph claims five languages, which wants
item 7, and the system text size, which wants a look at an iPhone with
Larger Text turned up. The Helpful Details claim spoken turns, which
wants item 5. All three before this is sent.

## 2. Press pitches

Plain text, about 150 words each, one pitch to one outlet at a time.
Personalize the greeting when you know who covers apps there; no
contact names are given here because none are known. Each pitch says
who it is for and what it depends on.

### Senior tech and lifestyle

For outlets such as AARP's technology coverage and Senior Planet. It
needs the stores live, or drop the store links and say "in any web
browser". The live-play line goes if item 3 is not done.

**Subject** (*set here*: a subject a phone's inbox shows whole)
<!-- limit=60 unit=chars -->
```text
A free Hearts game with no ads, no account, nothing to buy
```
Count: 58 of 60 characters

<!-- limit=170 unit=words -->
```text
Hello,

Hearts is a game many of your readers learned at a kitchen table. Open Hearts is a free version of it with no ads, no coins and no sign-up. It runs in any web browser at [PLAY URL], and on iPhone and Android: [APP STORE LINK], [GOOGLE PLAY LINK].

For your readers:

- Playing against the computer is free for good: no ads, no account, and it never asks for a name, an email or a card.
- Tap a card you can't play and it says which rule stopped you, which helps anyone returning to the game.
- Words get bigger with the browser's zoom or, in the apps, the phone's text size, and on a tablet the cards are bigger too.
- It's in English, Spanish, Portuguese, German and French.

An optional $2.99-a-year subscription lets people play each other online. Nobody needs it.

I'm the developer and glad to answer questions or send screenshots: [CONTACT EMAIL].

[YOUR NAME]
```
Count: 161 of 170 words

### Accessibility

For AppleVis and outlets like it. AppleVis is run by its members: an
app usually reaches it as an App Directory entry or a forum post in
its gaming section, so the same text can open a forum post as well as
an email. It needs the iOS app live and item 5 done. If VoiceOver on
an iPhone was tried, say so and by whom in place of "Nobody blind has
played it yet".

**Subject** (*set here*)
<!-- limit=60 unit=chars -->
```text
Open Hearts, a free Hearts game: VoiceOver reports wanted
```
Count: 57 of 60 characters

<!-- limit=170 unit=words -->
```text
Hello,

Open Hearts is a free Hearts game for iPhone and iPad ([APP STORE LINK]), with no ads, no account and nothing to buy. Before launch we played a whole hand of the web version using only its accessibility tree, and fixed what that turned up:

- Each card is a button with its name, "queen of spades"; cards you can't play are disabled.
- Each seat says who is there, their score and where they sit: "Mark Antony: 0 in the game, 0 this hand, on your left".
- "Your turn" and who took each trick are announced as they happen.
- Scores after a hand read as sentences.

Two gaps are known: a card picked for the pass is read as "current" rather than "selected", and cards on the table are read in seat order, with the led card marked.

Nobody blind has played it yet, and I would value reports from people who will: [CONTACT EMAIL].

[YOUR NAME]
```
Count: 161 of 170 words

### Open-source and indie development

For newsletters and sites that cover open-source work and indie
games, Changelog News or It's FOSS for instance. It needs item 1, and
item 3: without live play on production there is nothing to try that
the pitch is about.

**Subject** (*set here*)
<!-- limit=60 unit=chars -->
```text
Peer-to-peer Hearts with a mental-poker deal, MIT-licensed
```
Count: 58 of 60 characters

<!-- limit=170 unit=words -->
```text
Hello,

Open Hearts is a Hearts game in Flutter, MIT-licensed ([SOURCE URL]; play at [PLAY URL]). Two parts of it may interest your readers.

Live tables have no dealer. The four devices shuffle in turn, each publishing a zero-knowledge proof (Barnett–Smart with a Bayer–Groth argument, from the geometryxyz/mental-poker crate compiled to WebAssembly), so the order is fair if any one shuffler is honest and each player can open only their own cards. Bot seats are held by a jury of other players' devices, so nobody at the table sees a bot's hand either. Cards travel over WebRTC; public Nostr relays make the introductions.

The bots are readable heuristics, not a model: forty named characters at nine strengths, calibrated over 20,000 simulated tables and rated alongside people.

Playing alone is free; live play is $2.99 a year, which pays for relays and TURN. The crypto crate is unaudited research code, and scrutiny is welcome.

[YOUR NAME]
```
Count: 155 of 170 words

## 3. Senior-centre kit

### The handout

One page, for a notice board or a table at a card afternoon. The
printable version is `senior-center-handout.html`: open it in a
browser and print. Body text is 18 points or larger, black on white,
in Arial or Helvetica, and nothing is loaded from anywhere else.

It prints on one page of US Letter and of A4, measured rather than
assumed: printed to PDF on each from headless Chromium, and laid out
at A4's width and Letter's height together, the worst case, where it
takes 930 of the 973 pixels there are. It also fits with the
placeholders filled by longer real values. On a phone's screen it
becomes one column with no sideways scrolling.

Fill `[PLAY URL]`, `[HELP CONTACT]` and `[SITE URL]` in that file
before printing. The placeholders are highlighted in yellow, so a
missed one is obvious on paper. The "Ask:" line is left blank on
purpose, for the centre to write in a name.

The text, kept the same as the HTML:

> **Open Hearts**
> Free on your phone, tablet or computer
>
> The card game for four: you and three computer players. Try not to
> take hearts or the queen of spades. Lowest score wins.
>
> **Start playing**
> 1. Open the internet browser: Safari, Chrome or Edge.
> 2. At the top, type this address, then press Go or Enter:
>    `[PLAY URL]`
> 3. Tap the gold button that says **Play solo**.
> 4. At the start of a hand you pick 3 cards to give away: tap them,
>    then tap **Pass**. Now you're playing.
>
> Tap a card you can't play, and the game tells you why. Save the page
> as a bookmark to find it again.
>
> **It's free**
> - Playing alone is always free.
> - No ads. No sign-up.
> - No name, email or card needed to play alone.
> - "Live play" costs money. It is for playing people online. You
>   don't need it.
>
> **Make it bigger**
> - Computer: hold **Ctrl** and press **+**. Mac: **⌘** and **+**.
>   **Ctrl** and **0** puts it back.
> - Phone or tablet: find **Zoom** in the browser's menu.
> - A tablet shows bigger cards than a phone.
>
> **Need help?**
> Ask: ______________________ or `[HELP CONTACT]`
>
> Also in Español, Português, Deutsch and Français, set by your device.
> Free, open-source software: `[SITE URL]`

Two lines depend on things outside this file. "Phone or tablet: find
Zoom" is item 6. "Live play costs money" is there because the front
door shows "Live play" and its price whenever the paid tier is
offered, and a reader who meets a price without warning may stop. If
the operator turns the offer off (`offer: false`, doc 06), the line
can go. The page has no room to spare: a longer line will need
something else shortened, and the measurement repeated.

### Cover letter to activity directors

One page, to go with a few printed handouts. The live-play paragraph
stays even if live play is not open: the door shows the price either
way, and saying so first is what keeps a resident from worrying about
a charge.

<!-- limit=250 unit=words -->
```text
Dear [ACTIVITY DIRECTOR NAME],

I make Open Hearts, a free version of the card game Hearts. People play it against three computer players on a phone, a tablet or a computer, in the web browser they already have. I'm writing because it may suit residents who enjoy cards but can't always find a foursome.

What may matter to you:

- Playing alone is free and will stay free. There are no ads, no account and nothing to sign up for. To play alone it never asks for a name, an email address or a card number.
- If someone taps a card they can't play, it tells them which rule stopped them, so it is forgiving for people coming back to the game.
- The words get bigger with the browser's zoom, and on a tablet the cards and words are larger than on a phone.
- It follows the device's language: English, Spanish, Portuguese, German or French.

The first screen also shows "Live play" and a yearly price. That is an optional subscription for playing with other people online, and nobody needs it to play alone.

I've enclosed a one-page handout you are welcome to copy. If anything doesn't work, or residents find something hard to read or confusing, I would like to hear about it: [HELP CONTACT].

With thanks,

[YOUR NAME]
Open Hearts · [SITE URL]
```
Count: 228 of 250 words

## 4. Community posts

Rules for both: say who you are in the first line; post once per
community and not the same text to several on the same day; stay in
the thread for the first day and answer what is asked, critical
things first; post from an account that takes part there otherwise.

### Reddit, r/cardgames

Read the sidebar on the day. This was written without it: Reddit
refused the fetch, and a third-party list from September 2026 says
r/cardgames allows self-promotion. Use a text post, not a link post.
It needs items 1 and 3; without live play, cut section 1 down to the
solo paragraph and lead with the bots.

**Title** (Reddit's limit)
<!-- limit=300 unit=chars -->
```text
I made a free, open-source Hearts where the cards are shuffled and dealt between the players' devices, with proofs, so no one at the table, and not me, can rig a deal. The bots' code is public too. Card players, please pick it apart.
```
Count: 233 of 300 characters

**Body** (Reddit's limit, in its Markdown)
<!-- limit=40000 unit=chars -->
```text
**Disclosure: I'm the developer.** Open Hearts is a Hearts game I've been building in the open. Playing against bots is free, with no ads and no account: in a browser at [PLAY URL], and on iPhone and Android ([APP STORE LINK], [GOOGLE PLAY LINK]). Two parts of it might interest people here, and I'd like them picked apart.

**1. A deal nobody at the table can rig**

Every online card game asks you to trust its shuffle. At a live table in Open Hearts there is no dealer and no server holding the deck. Each of the four seats takes the encrypted deck in turn, shuffles it in secret, and publishes a proof that the result is the same 52 cards reordered, without showing the order. One honest shuffle is enough to make the order fair. Each player can open only their own thirteen cards, and a card you play has to be one you were dealt. When the hand ends every secret is published, and anyone can replay and check the whole hand.

It's "mental poker" (Barnett–Smart, with a Bayer–Groth shuffle argument), using an existing Rust implementation compiled to WebAssembly. The price is a few seconds of "Shuffling (2 of 4)" at the start of each hand in a phone's browser.

Empty seats are filled by bots, and a bot always says it is one. A bot's seat, its shuffle included, is played by a stranger's device drawn at random, with what it takes to open the seat split among a few more, so nobody at the table can see its cards either.

Solo games are dealt differently, because there's nobody to prove anything to: a 256-bit seed from the device's secure random generator, then HMAC-SHA-256 and an unbiased Fisher–Yates shuffle. "Copy record" at the end of a game gives you the whole game as one line of text, and the docs have a Python script of about twenty lines that deals the same hands from it with nothing but the standard library.

**2. Bots you can read and argue with**

The bots are named rules of thumb, not a black box: forty characters (Romeo, Cyrano, Casanova, Don Juan…), each the same policy with a few thresholds moved, so one can't hold on to the queen and another runs at the moon on a hand nobody else would. Measuring them taught me a few things:

- Leading the lowest card in your hand, whatever its suit, won about two percentage points more games than leading low from your shortest suit.
- Never shooting the moon costs about six percentage points of games won, so every bot goes for it when a hand is plainly a shot. With four bots at the table, someone shoots in about one hand in fourteen.
- Every bot, even the weakest, breaks up someone else's run at the moon. Against three players who never defend, a player who always runs wins 44% of games.
- Each character comes at nine strengths. The weakest finishes ahead of the strongest a little over one time in four, which says something about how much of Hearts is the deal.

In live play the bots are rated like people, from real results, and you're seated with bots near your rating. Their known weakness: they don't yet read what an opponent's discards say about that opponent's hand.

**What it doesn't do**

- It can't stop two players sharing hands over a phone call. Nothing can.
- The shuffle library is research code that hasn't been audited. I've fixed one thing in it, and more eyes are welcome.
- There's no chat, on purpose.
- At live tables your display name, picture and results are public: ratings are worked out from a signed record anyone can read.

**Rules:** the standard ones. Pass left, right, across, then hold; the 2♣ leads; no points on the first trick; hearts can't be led until broken; the Q♠ is 13; shoot the moon and everyone else takes 26. Solo games go to 50; live games to 50 or 100.

**Money:** playing alone is free for good. Live play against people is $2.99 a year, on the web for now, and pays for the relays and for connections that can't go direct.

**What I'd like from you:** hands where the bots play badly ("Tell us what's broken" in the table's menu can attach the game's record, which I can replay trick by trick), rules or options you expect and can't find, and whether a deal you can check is something you'd care about at a table of strangers.

Code (MIT): [SOURCE URL]. How the deal works: [SOURCE URL]/blob/main/docs/03-fair-deal.md
```
Count: 4253 of 40000 characters

### Hearts players' forums

Shorter, about the game rather than the machinery, for places where
people discuss Hearts itself: the Hearts forums on BoardGameGeek, a
Hearts subreddit or group if an active one exists. Check each one's
rules on promotion first. It needs item 1 only if you keep the source
link; it works with the solo game alone.

**Title** (*set here*)
<!-- limit=100 unit=chars -->
```text
Open Hearts: a free Hearts with forty named bots and no ads. I'm the developer; critique welcome
```
Count: 96 of 100 characters

<!-- limit=200 unit=words -->
```text
I'm the developer of Open Hearts, a free Hearts game: [PLAY URL] in a browser, or [APP STORE LINK] and [GOOGLE PLAY LINK]. Playing against the bots is free for good, with no ads and no account.

Standard rules: pass left, right, across, then hold; the 2♣ leads; no points on the first trick; hearts can't be led until broken; the queen of spades is 13; shoot the moon and everyone else takes 26. Solo games go to 50.

The bots are forty named characters on one set of rules of thumb, each with a temperament. Things they all do because they measured better: lead the lowest card in hand, empty a short suit in the pass, and always break up someone else's run at the moon. They don't yet read what your discards say about your hand.

What I'd like from Hearts players: where do the bots make plays you never would? "Tell us what's broken" in the table's menu can attach the game, so I can replay it. And which rule options do you miss?

Live play against people is optional, $2.99 a year on the web. None of the above needs it.
```
Count: 195 of 200 words
