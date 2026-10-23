# Change the terms, the privacy policy or the price

Use this guide to change the terms of use or the privacy policy on the site, or the price of a web subscription. Every published version of either document is an entry in `site/ledger.json`, and production publishes nothing the ledger doesn't account for ([why, and what holds it](../explanation/service.md#changing-the-terms)).

| Command | What it does |
|---|---|
| `./oh terms status` | Says where each document stands: its newest entry, whether this checkout matches it, the version the site serves, what a deploy would publish, and how many web subscribers were told of each change. |
| `./oh terms record` | Writes the ledger entry for a change this checkout makes. |
| `./oh terms notified` | Records the day the App Store and Google Play were told of a material change. |
| `./oh terms notify` | Emails web subscribers a published change that matters to them. Nothing else sends it: no deploy emails anyone. |
| `./oh terms eula` | Prints the terms as plain text, for the App Store's licence agreement. |

Each says what it would do and changes nothing without `--apply` ([the oh command](../reference/oh.md)).

## Before you begin

- Decide what kind of change it is. The kind decides who is told:

  | Kind | What it is | Who is told |
  |---|---|---|
  | `minor` | Wording that changes nobody's rights or duties: a typo, a clearer sentence, a link that moved. | Nobody. |
  | `material` | Anything else: what a subscriber pays or gets, what anyone may do, what we may do, what is collected or kept, refunds, ending, disputes. | Every device at the front door, every web subscriber by email, and, while either app is in its store, Apple and Google. |
  | `price` | A new price. | As a material change. |

  If you're not sure, it's `material`.

- Pick the day you'll publish it. The page's "Last updated" is that day, and a production deploy refuses a version dated any other day.

## Make the change

1. Edit the text in all five languages: `terms.*` or `privacy.*` in `site/strings/en.json`, `es.json`, `pt.json`, `de.json` and `fr.json`, and `site/pages/terms.html` or `privacy.html` if the page's sections change.

1. Run the site's tests:

   ```bash
   node --test site/*.test.mjs
   ```

   The test `each document is word for word what its newest entry in the ledger fingerprints` fails. It fails for any change to what a reader sees, a link included, until the ledger has an entry for it.

## Record the change

1. See the entry it would write, dated the day you'll publish:

   ```bash
   ./oh terms record terms --change material --date 2026-11-02
   ```

   For the privacy policy, name `privacy` instead of `terms`.

1. Write it:

   ```bash
   ./oh terms record terms --change material --date 2026-11-02 --apply
   ```

   The entry has the day, the text's fingerprint in all five languages, the kind of change and, for the terms, the price from `config/openhearts.json`.

1. In `site/ledger.json`, write under the new entry's `summary` what changed, in each language: a sentence or two of plain text, at most 280 characters. It is what subscribers are emailed and what the app shows. Both show only each document's newest change, so if an earlier change to the same document hasn't been published and told yet, the summary says what that one changed too.

1. Run the site's tests again, and open a pull request. The reviewer sees the entry beside the text.

If you change the text again before the pull request is merged, run `./oh terms record` again: it brings the branch's own entry up to date instead of adding another. An entry already on `main` can't be changed, except to fill in the day the stores were told.

## Tell the app stores

Only while either app is in its store (`stores` in `site/build.mjs` names a listing), and only for a material or price change.

1. Tell Apple and Google of the change, in the way each asks developers to report a significant change to their terms or privacy policy.

1. Record the day:

   ```bash
   ./oh terms notified terms --on 2026-10-30 --apply
   ```

   Commit it with the change, or in its own pull request if the change is on `main` already.

A production deploy refuses a material change the stores weren't told of.

## Update the licence agreement in the App Store

Only for the terms, and only while the app is in the App Store. The terms are the app's licence agreement there, in place of Apple's standard one, so App Store Connect has to hold the same text.

1. Once the change is published, print the terms as plain text:

   ```bash
   ./oh terms eula
   ```

1. In App Store Connect, open the app's **App Information**, and under **License Agreement** paste the text in place of the one there.

## Publish it

On the day in the entry, once the pull request is merged:

```bash
./oh deploy all --apply
```

It says which versions it publishes. It refuses, and says why, if:

- the site serves a version that isn't in the ledger;
- the newest version would go live dated another day than today (in UTC; yesterday is allowed, for time zones west of it);
- a material change wasn't told to the stores while an app is in its store.

It emails nobody.

If the day has passed, date the version again in a new pull request. An entry already on `main` can't change, so this adds one with the same text, a minor change, that only publishes it later: `./oh terms record terms --change minor --date <today> --apply`. Its summary says so, such as "Published on 23 October 2026: the terms of 19 October 2026, unchanged." Subscribers are still told of the material change, by its own entry.

## Tell subscribers

For a material or price change only. Once it's published, every device says at the front door, in one line, that the terms of use or the privacy policy changed, for 60 days or until it's dismissed. **What changed** beside it shows each document's summary, with a link to the whole document. Subscribers who bought in the App Store or Google Play are told this way, since we have no address for them.

Web subscribers are emailed only when you send it, on the day you publish:

1. Once `./oh deploy all --apply` has finished, see who would be told:

   ```bash
   ./oh terms notify
   ```

   It names each document's newest published change of the last 60 days that matters to subscribers, with how many web subscriptions are to be told and how many were told already, and shows the email as it reads in English. Read it before you send it.

1. Send it:

   ```bash
   ./oh terms notify --apply
   ```

   Each web subscription that is active, on trial or overdue, and that began on or before the day of the change, is sent one email of every change it wasn't told of: each document's newest change, its summary in the language the subscription was bought in, with a link to the document, dated the day the document as it now reads was published. For the terms, the email names the renewal they first apply at. Each subscription is told once: run it again after a notice didn't go, and it tells only those it hasn't. A subscription with no email address in Stripe is noted and not tried again.

1. Check that everyone was told:

   ```bash
   ./oh verify
   ```

   It fails while a published change has a web subscription that wasn't told.

The terms apply a change to a subscription only from its first renewal at least 30 days after its subscriber was told, so an email sent late moves that renewal later; it never lets a change apply to someone who wasn't told. The 30 days are `APPLIES_AFTER_DAYS` in `service/functions/notices.mjs`, which a test holds to the terms' "Changes to these terms" in every language.

## Change the price

The price is `price` in `config/openhearts.json`, in cents: `{ "amount": 599, "currency": "usd" }`. The terms, the front page, Stripe's price and the checkout are made from it.

1. Change `price` in `config/openhearts.json`, and `priceAmount` in `app/lib/net/buying.dart` to the same price as English writes it. The site's tests hold the two together.

1. Record it as a price change, and write the summary:

   ```bash
   ./oh terms record terms --change price --date 2026-11-02 --apply
   ```

1. Publish it as above. Then make Stripe's price match:

   ```bash
   ./oh infra --only stripe --apply
   ```

   This makes a new Stripe price and moves the lookup key to it. Until then the checkout doesn't sell, because it sells only at the price the terms state, and `/api/health` says `not the price the terms state`.

1. Change the price in App Store Connect and the Play Console separately. Apple and Google tell their own subscribers of an increase, and ask for consent where the law requires it.

Web subscribers who already pay keep the price they bought at: Stripe keeps each subscription on its price, and nothing in `oh` moves one. Don't move them in Stripe's dashboard.

## Check where a change stands

```bash
./oh terms status
```

For each document it prints the newest entry, whether this checkout matches it, the version the site serves, each version waiting to be published, and, with Cloudflare credentials, how many web subscriptions were told of each published change.
