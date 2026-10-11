# Add a language

Use this guide to add a language to the app, the phone builds' language settings and the marketing site.

The examples add Italian, code `it`. Use the language's two-letter code everywhere the code appears, and set it in your shell for the commands below:

```bash
code=it
```

## Before you begin

- Have translations of the app's words (`app/lib/l10n/app_en.arb`) and of the site's words (`site/strings/en.json`). The English `.arb` file describes where each message appears.
- Install Flutter and Node, and run `flutter pub get` in `app/`.
- Run the commands from the repository root.
- To make the site's pictures of the game, you also need what the browser suites need. See [Run the browser suites](run-the-browser-suites.md#before-you-begin).

## Add the language to the app

1. Copy the English words to a file for the new language:

   ```bash
   cp app/lib/l10n/app_en.arb "app/lib/l10n/app_$code.arb"
   ```

1. In the new file, set `"@@locale"` to the code, translate every message, and delete the `@` description entries. The translations keep only `@@locale` and the messages. Keep every placeholder in braces, such as `{name}`, that the English message has.
1. Generate the localization classes again. They are committed, so commit the changed `app/lib/l10n/app_localizations.dart` and the new `app_localizations_it.dart` with the `.arb` file:

   ```bash
   (cd app && flutter gen-l10n)
   ```

   `AppLocalizations.supportedLocales` now includes the language, and `?lang=it` selects it.

1. Add the language, by its own name, to `languageNames` in `app/lib/l10n/l10n.dart`. This is the language list on the web app's About page:

   ```dart
   const languageNames = {'en': 'English', /* … */ 'fr': 'Français', 'it': 'Italiano'};
   ```

1. Add the language to Android's per-app language setting, in `app/android/app/src/main/res/xml/locales_config.xml`:

   ```xml
   <locale android:name="it"/>
   ```

1. Add the language to `CFBundleLocalizations` in `app/ios/Runner/Info.plist`:

   ```xml
   <string>it</string>
   ```

## Add the language to the site

1. Add the language to `languages` in `site/build.mjs`. `lang` is for `<html lang>` and `locale` for `og:locale`:

   ```js
   { code: 'it', lang: 'it', locale: 'it_IT', name: 'Italiano' },
   ```

1. Copy the English words and translate every string:

   ```bash
   cp site/strings/en.json "site/strings/$code.json"
   ```

   Keep each string's markup as it is in English: the same tags, links and `{{…}}` placeholders. `common.translationNote` is the one string English leaves empty. In a translation it is the note, shown on the privacy policy and the terms, that the English version prevails.

1. Add the code to `others` in `site/public/lang.js`, so an English page sends a browser that prefers the language to its pages.
1. Add the code to `languages` in `e2e/site_shots.mjs`.
1. Make the site's pictures of the game in the new language. The site build reads `broken-`, `cancel-` and `add-` pictures for every language, so put English copies in place first, then let `e2e/site_shots.mjs` replace them:

   ```bash
   for p in broken cancel add; do cp "site/public/img/$p-en.png" "site/public/img/$p-$code.png"; done
   ./e2e/build.sh && node e2e/site_shots.mjs
   ```

   Look at the new pictures in `site/public/img/` before you commit them.

## Check it worked

1. Check that no message is left untranslated. `flutter gen-l10n` says how many messages a language lacks, and lists them in `app/build/untranslated.json`. The new language must lack none.
1. Run the app's language tests. They check that every language has every message with the English blanks, that every card and rule has a name of its own, that the Android and iOS lists equal the app's languages, and that every screen fits in every language:

   ```bash
   (cd app && flutter test test/l10n_test.dart)
   ```

1. Run the layout matrix, which lays out the table at every shape and text size in every language (`app/test/fits.dart`):

   ```bash
   (cd app && flutter test -t slow)
   ```

1. Run the site's build test. It checks that the language has every string with English's markup, and that every page is built in it:

   ```bash
   node --test site/build.test.mjs
   ```

1. Run the site in a browser, in every language:

   ```bash
   node e2e/site.mjs
   ```

1. No test checks `languageNames`. Open the web app's About page and check that the language is in its list.

## Learn more

- [Screens](../explanation/screens.md#text-size): why every screen is laid out in every language.
