# Update the App Store and Google Play listings

Use this guide to change what the App Store and Google Play say about the app, to make the listings' pictures, and to put both in App Store Connect and the Play Console.

The listings' words are in `site/store.json`: for each language, one listing for each store, and the store locales it goes to. `site/store.test.mjs` holds them to each store's limits. The pictures are made from the built app by `e2e/store_shots.mjs`, into `app/build/store/`, which git ignores.

## Before you begin

- To make the pictures, you need what the browser suites need. See [Run the browser suites](run-the-browser-suites.md#before-you-begin).
- Run the commands from the repository root.

## Change the words

1. Edit the listing in `site/store.json`: `apple` for the App Store and `google` for Google Play, under the language's code. A description is a list of lines, one to a line of the store's text field. Both stores show plain text, and the App Store's words can't name another platform.
1. Run the listing's test:

   ```bash
   node --test site/store.test.mjs
   ```

   It checks that every language the site has has a listing in both stores; that every field is within its store's limit, counted in characters; that Google Play's alt text is there for every picture `e2e/store_shots.mjs` takes, and the feature graphic; that the App Store's keywords are at most 100 bytes, each more than two characters long and none of them a word of the app's name; that the App Store's words name no other platform; that nothing is markup; that every link is to a page of the site, by the address the site gives it, in the listing's own language, and the App Store's support, marketing and privacy policy links to those pages; and that the contact details are the site's, and the copyright a year and a name.

| Store | Field in the store | In `site/store.json` | At most |
|---|---|---|---|
| App Store | Name | `apple.name` | 30 characters |
| App Store | Subtitle | `apple.subtitle` | 30 characters |
| App Store | Promotional Text | `apple.promotionalText` | 170 characters |
| App Store | Description | `apple.description` | 4,000 characters |
| App Store | Keywords | `apple.keywords` | 100 bytes |
| App Store | Support URL | `apple.supportUrl` | |
| App Store | Marketing URL | `apple.marketingUrl` | |
| App Store | Privacy Policy URL | `apple.privacyUrl` | |
| Google Play | App name | `google.title` | 30 characters |
| Google Play | Short description | `google.shortDescription` | 80 characters |
| Google Play | Full description | `google.fullDescription` | 4,000 characters |
| Google Play | Alt text, for each screenshot and the feature graphic | `google.alt`, by the picture's name (`feature` for the feature graphic) | 140 characters |

The rest of the file is the same in every language: `copyright` for the App Store's Copyright field, `category` for each store's category, and `contact` for Google Play's contact details (the email and the website) and its privacy policy.

## Make the pictures

1. Build the app the way the browser suites expect it:

   ```bash
   ./e2e/build.sh
   ```

1. Make every picture:

   ```bash
   node e2e/store_shots.mjs
   ```

   Each screenshot is a moment the script brings the app to, from a fixed deal, played by the same few rules in every language, so every language and size shows the same game. The game won is pictured `confettiAt` milliseconds into its confetti, on a clock the script holds, so it too is the same every time. The live table is the exception: a live deal is never the same twice. On a machine of four cores, each size takes about half an hour, and the whole run about two hours.

   To make fewer, name a size, a language or a picture:

   ```bash
   node e2e/store_shots.mjs --size ipad-13 --lang de --only won
   node e2e/store_shots.mjs --only graphics
   ```

   `--only graphics` makes Google Play's feature graphics and icon alone.

1. Look at every picture before you upload it. They are of the app as it runs in a browser, at each device's size: they show no status bar, and the app's letters are Roboto, where an iPhone or iPad shows Apple's system font.

| File in `app/build/store/` | What it shows |
|---|---|
| `<size>/<language>/1-play.png` | A trick under way, the player last to it |
| `<size>/<language>/2-live.png` | Four people at a table from a room's link |
| `<size>/<language>/3-learn.png` | The hand that teaches, at its note on a trick taken |
| `<size>/<language>/4-won.png` | A game won, its score sheet in confetti |
| `<size>/<language>/5-pass.png` | Three cards chosen for the pass |
| `feature-graphic/<language>.png` | Google Play's feature graphic, from the site's share image, in the language's words from the site |
| `google-play-icon.png` | Google Play's icon: the App Store's, at 512 pixels |

## Put them in the stores

Each language's listing goes to every locale its `stores` entry in `site/store.json` names:

| Language | App Store | Google Play |
|---|---|---|
| English | `en-US` | `en-US` |
| Spanish | `es-ES`, `es-MX` | `es-ES`, `es-419` |
| Portuguese | `pt-BR` | `pt-BR` |
| German | `de-DE` | `de-DE` |
| French | `fr-FR` | `fr-FR` |

Upload each size's screenshots, in their numbered order, where the store asks for that display:

| Size | Pixels | Where it goes |
|---|---|---|
| `iphone-6.9` | 1320 × 2868 | App Store: iPhone with Dynamic Island (large display) |
| `iphone-6.3` | 1206 × 2622 | App Store: iPhone with Dynamic Island (medium display), which the App Store requires |
| `ipad-13` | 2752 × 2064 | App Store: iPad 13" display, which the App Store requires of an app that runs on iPad |
| `android-phone` | 1080 × 1920 | Google Play: phone screenshots |

App Store Connect makes the smaller iPhone and iPad sizes from these. On Google Play, each language's screenshots and feature graphic go with its translation of the listing, each with its alt text from `google.alt`, and the icon with the main store listing; a language without pictures of its own shows the default language's. Google Play's tablet screenshots are optional, and none are made: Google asks for them at 16:9 or 9:16, which the iPad's are not.

## Check it worked

1. `node --test site/store.test.mjs` passes.
1. `e2e/store_shots.mjs` ended without an error. It refuses to write a picture that isn't the size its store takes, or that has an alpha channel where the store takes none: every picture but Google Play's icon, which must have one and be 1 MB at most.
1. In App Store Connect and the Play Console, each locale shows its own words and pictures.

## Learn more

- [What the App Store and Google Play are told](../reference/store-answers.md): the answers to each store's privacy, content and review questions.
- [Build a phone release for the App Store or Google Play](cut-a-phone-release.md)
- App Store Connect's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), and Google Play's [preview assets](https://support.google.com/googleplay/android-developer/answer/9866151).
