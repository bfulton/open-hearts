# What the App Store and Google Play are told

Before an app can be submitted, App Store Connect and the Google Play Console each ask what it collects and what it contains: Apple's App Privacy and age rating, Google's Data safety, content rating and target audience. This page gives the facts each question turns on, for the phone apps, from the [privacy policy](https://openhearts.game/privacy) and the code. A store's review rejects an app whose answers don't match what it does, so when the privacy policy changes ([change the terms](../how-to/change-the-terms.md)), check this page too.

The forms change from year to year. The facts below are sorted by the categories both stores use, not question by question.

## What the phone apps collect

Everything below is collected only once a player subscribes, except where the table says otherwise. A player who only plays alone sends nothing. The phone apps send no diagnostics: New Relic is in the web game only.

Every row is linked to the player's account, by the account's number. Nothing is used to track anyone across apps or sites, and nothing is used for advertising.

| What | Kept where, and for how long | Apple's category | Google's category | Purpose |
|---|---|---|---|---|
| The name a player plays under. It may be a real name. | The service, with the account. The relay, a day. Finished games, until the account is deleted. | Contact Info › Name | Personal info › Name | App functionality |
| The player's picture, 192 × 192 pixels. Optional. | The service, with the account. A copy is kept until a year after it stops being the account's. The relay, a day. | User Content › Photos or Videos | Photos and videos › Photos | App functionality; safety: it is checked against known images of child sexual abuse, and by Cloudflare's classifier |
| The account's number, each device's public key, and a scrambled form of the Apple or Google sign-in. | The service, while the account lasts. | Identifiers › User ID | Personal info › User IDs; Device or other IDs (the device's key) | App functionality, account management, fraud prevention (one device at a time) |
| The subscription: which store, and the dates it runs to. | The service, while the account lasts. | Purchases › Purchase History | Financial info › Purchase history | App functionality, account management |
| Results and finished live games: every card, signed. | The relay, for as long as ratings are worked out from them. The service, for good, without the name once the account is deleted. | User Content › Gameplay Content | App activity › Other actions | App functionality |
| Which device the account is using, and at which table. | The service, replaced each time another device opens the game. | Usage Data › Product Interaction | App activity › App interactions | App functionality |
| A report one player makes of another: what they chose and wrote. | Emailed to the operator. The service notes for a day that it was sent. | User Content › Other User Content | App activity › Other user-generated content | App functionality (moderation), fraud prevention and safety |

### What the phone apps don't collect

- **Email addresses.** A store's purchase brings none, and the Apple and Google sign-ins ask for no name or email. A web subscriber's address is Stripe's, and the phone apps never see it.
- **Payment details.** The App Store and Google Play take the payment.
- **Location.** Cloudflare sees a device's IP address, as any server does. Open Hearts doesn't log it or work out a location from it.
- **Contacts, messages, audio, files, browsing or search history, health, or diagnostics.** There is no chat: reactions are a fixed set, passed on and not kept.
- **The camera's pictures.** The camera is used only to scan a code that adds a device, and the picture stays on the device.
- **What is passed on but not kept.** While a player waits for a game, their name, rating, look and pace go through the relay, as does whether a device is online. A watched table's state is passed on the same way. The relay keeps none of it. Apple counts only data kept longer than a request takes, and Google calls this ephemeral processing.
- **Tell us what's broken.** It opens a GitHub issue in the browser, filled in, for the player to post under their own GitHub account. Nothing goes to Open Hearts unless the player posts it, and then it goes to GitHub.

### Google's Data safety

- **Shared with third parties: no.**
  - Cloudflare (hosting, the image classifier, TURN, sending email) works for Open Hearts as a service provider.
  - So do Project Arachnid and Microsoft's PhotoDNA. They are sent only a fingerprint of a picture.
  - A report to NCMEC is a legal obligation.
  - What live play shows other players is the player's own act of playing live: each of these is one of Google's exemptions from "shared".
- **Encrypted in transit: yes.** Everything goes over HTTPS or secure WebSockets, and play between devices over WebRTC, which is always encrypted.
- **Can users ask for their data to be deleted: yes.**
  - In the app: menu › Subscription › Delete account.
  - Without a device: by email, as `https://openhearts.game/support#delete` says. That page is the data deletion URL Google asks for.
- **Account creation: yes.** Subscribing makes an account; there is no username or password.

## What the apps contain

For Apple's age rating and Google's content rating (IARC):

- **No violence, sexual content, nudity, profanity, horror, fear, drugs, alcohol, tobacco, medical or wellness content.**
- **No gambling, and no simulated gambling.** Hearts is played for points. Nothing is wagered, and there are no prizes, contests or loot boxes.
- **No advertising.**
- **No unrestricted web access.** Links open the system browser at Open Hearts' own pages, the store's subscription page, and GitHub.
- **No social feed.** Nothing players make is put in a feed or recommended. Names and pictures are shown only at the table a player sits at or watches.
- **No chat or messaging.** Reactions are a fixed set of six, shown for a moment.
- **User-generated content: yes.** Players choose a name and picture that strangers at a live table see. The moderation:
  - names are filtered;
  - pictures are checked against known images of child sexual abuse and by Cloudflare's classifier;
  - players can report and block;
  - the operator can take a name or picture off and suspend an account ([handle a report](../how-to/handle-a-report.md)).
- **Users interact: yes,** by playing at the same table. **Shares location: no.**
- **Digital purchases: yes.** One auto-renewing yearly subscription, for live play.

**Age.** The terms let anyone play alone, require a player to be at least 13 to play live, and let a player under 18 subscribe only with a parent or guardian's agreement. If a store's form comes to a lower rating than 13+, raise it to 13+ to match the terms. In Google Play's target audience, choose 13 and over: the app isn't designed for children, so Google's Families policy doesn't apply.

**Age assurance.** Before live play, and before the store's purchase sheet, the phone apps ask the store whether the player may play live: the App Store through Declared Age Range, with the single age gate 13, and Google Play through its Age Signals ([live play](../explanation/live-play.md#getting-to-a-table)). Live play closes for a range wholly under 13, for a supervised player whose parent has not approved or has declined the app's latest significant change, and where Google Play needs the age confirmed. The answer is not kept and not sent, so it is not data the app collects: it belongs in neither Apple's App Privacy nor Google's Data safety. The privacy policy says it under *Children*.

## For the reviewers

- **Getting into live play.** Live play needs a subscription.
  - An App Store reviewer buys it in Apple's sandbox. The service accepts App Store-signed sandbox purchases, and only testers you invite can make those.
  - Google's reviewers need access given in Play Console › App access. Subscribe on the web for a review account, and give them a backup code with the steps: menu › Activate subscription, then type the code.
- **A table to play at.** A reviewer alone gets a live table: when nobody else is waiting, bots fill the empty seats after 10 seconds. Say so in the review notes, and that signing in is optional.
- **The licence agreement.** In App Store Connect, the app's licence agreement is the terms, from `./oh terms eula` ([change the terms](../how-to/change-the-terms.md#update-the-licence-agreement-in-the-app-store)).
- **The addresses.** Privacy policy `https://openhearts.game/privacy`, support `https://openhearts.game/support`, marketing `https://openhearts.game`.

## Encryption

App Store Connect asks on each upload whether the app uses encryption, and Google Play asks too. The facts:

- The apps use HTTPS and secure WebSockets, through the system.
- They use WebRTC's DTLS between devices.
- They sign every move with Schnorr signatures.
- The fair deal encrypts each card so that only the player who holds it can read it ([the fair deal](../explanation/fair-deal.md)).
- All of it is standard cryptography, and the source is public.

Whether that is exempt under the US Export Administration Regulations is for you, or counsel, to decide. Once it's decided, `ITSAppUsesNonExemptEncryption` in `app/ios/Runner/Info.plist` can answer it, so that uploads stop asking.
