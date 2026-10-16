# The oh command

<!-- Written by `./oh help --markdown` from ops/commands.mjs and ops/env.mjs. Change those, then run it again: ops/oh.test.mjs fails while this page and they differ. -->

`./oh`, at the repository root, is how the operator does everything that runs Open Hearts: acting on an account, releasing, and setting up what the deployment is made of. It needs Node 22 or later, and nothing installed.

Development tools, such as `./check.sh`, the chaos walk and the bot benchmarks, are not part of it: see [Tools](tools.md).

## How every command behaves

- **Nothing changes without `--apply`.** A command that changes anything says what it would do and stops; with `--apply` it does it.
- **`./oh help <command>`**, or `--help` after it, says what the command takes, what it needs and where its how-to is.
- **It prints no name, picture, code or email address.** Accounts, keys and rows only.
- **Exit status:** 0 when it did what it was asked, 1 when it could not, 2 when it was asked wrongly.

## Arguments

| Argument | What it is |
|---|---|
| `<account>` | an account (32 hex characters) or one of its devices' keys (64 hex characters) |
| `<query>` | a name the account plays under (or had taken off), or the email address its web subscription was paid with |
| `<what>` | `name`, `picture`, or `name,picture` |
| `<row>` | `app` (remote config), `service` (service settings) or `relay` (relay settings) |
| `<file>` | a JSON file holding the whole row |
| `<name>` | a secret's name, as `infra/cloudflare.mjs` lists it |
| `<platform>` | `ios` or `android` |
| `<document>` | `terms` (the terms of use) or `privacy` (the privacy policy) |

## Credentials

Each command reads what it needs from the environment, and says which are missing.

| Variable | What it is |
|---|---|
| `CLOUDFLARE_API_TOKEN` | A Cloudflare API token. Accounts: Workers KV Storage Edit, and Workers R2 Storage Edit to take a name off kept games. Deploys and infrastructure: what docs/how-to/apply-infrastructure.md lists. |
| `CLOUDFLARE_ACCOUNT_ID` | The Cloudflare account the project is in. |
| `STRIPE_API_KEY` | A live-mode Stripe secret or restricted key. Finding an account by email: Customers and Subscriptions read. Refunds and terminations: Subscriptions write, Refunds write, and Invoices read. Infrastructure: what docs/how-to/apply-infrastructure.md lists. |
| `NEW_RELIC_API_KEY` | A New Relic User key, for the monitors (oh infra). |
| `NEW_RELIC_ACCOUNT_ID` | The New Relic account the monitors are in. |
| `NEW_RELIC_REGION` | US or EU. |

## Accounts

Acting on an account, as the terms and the privacy policy allow.

### oh account find

```bash
oh account find <query>
```

Prints the accounts a name or an email address belongs to. A name is looked for among the names accounts play under and the names taken off and held; an email address, among web subscriptions, which needs `STRIPE_API_KEY`.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, STRIPE_API_KEY (for an email address)
- **How-to:** [suspend-an-account.md](../how-to/suspend-an-account.md#find-the-account)
- **Example:** `oh account find 'The Name They Play Under'`

### oh account show

```bash
oh account show <account>
```

Says how an account stands: suspended or not, its devices, whether its profile has a name and a picture, and what is held to put back. Never prints a name or a picture.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [suspend-an-account.md](../how-to/suspend-an-account.md#find-the-account)
- **Example:** `oh account show 0123456789abcdef0123456789abcdef`

### oh account suspend

```bash
oh account suspend <account> [--apply]
```

Suspends an account from live play at once, and stops its web subscription renewing. Its devices get no licence and no activation, and the one in use is cut off at the relay. Carried out by the service in the account's turn. A subscription bought in a store is said, with what to do by hand.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, STRIPE_API_KEY (for a web subscription)
- **How-to:** [suspend-an-account.md](../how-to/suspend-an-account.md#suspend-the-account)
- **Example:** `oh account suspend 0123456789abcdef0123456789abcdef --apply`

### oh account lift

```bash
oh account lift <account> [--apply]
```

Lifts a suspension: each device gets its licence again the next time it asks, and a renewal the suspension stopped starts again. A renewal the subscriber cancelled stays cancelled. A terminated account is not let back.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, STRIPE_API_KEY (for a web subscription)
- **How-to:** [suspend-an-account.md](../how-to/suspend-an-account.md#lift-the-suspension)
- **Example:** `oh account lift 0123456789abcdef0123456789abcdef --apply`

### oh account terminate

```bash
oh account terminate <account> [--apply] [--serious]
```

Ends an account under the terms: suspended for good, its web subscription ended now, and the unused part of its year refunded unless --serious. --serious is for a serious breach, such as cheating, harassment, illegal content or fraud, which the terms say earns no refund. A subscription bought in a store is said, with what to do by hand. Running it again refunds nothing more.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `STRIPE_API_KEY`
- **How-to:** [end-an-account.md](../how-to/end-an-account.md#terminate-an-account)
- **Example:** `oh account terminate 0123456789abcdef0123456789abcdef --apply`

### oh account refund

```bash
oh account refund <account> [--apply] [--full]
```

Refunds a web subscription, and ends it now: the unused part of its year, or with --full all of its last payment. A refund always ends the subscription, as the terms say, so that no device goes on playing on money given back. Running it again refunds nothing more.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `STRIPE_API_KEY`
- **How-to:** [end-an-account.md](../how-to/end-an-account.md#refund-a-web-subscription)
- **Example:** `oh account refund 0123456789abcdef0123456789abcdef --full --apply`

### oh account remove

```bash
oh account remove <account> <what> [--apply]
```

Takes the name, the picture or both off an account's profile, and holds them to put back. Taking the name off also takes it off every kept game the account played. A picture taken off is withheld at the relay too.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, (Workers R2 Storage Edit, for a name)
- **How-to:** [suspend-an-account.md](../how-to/suspend-an-account.md#take-a-name-or-picture-off)
- **Example:** `oh account remove 0123456789abcdef0123456789abcdef picture --apply`

### oh account restore

```bash
oh account restore <account> [--apply]
```

Puts back what remove held. A name taken off kept games stays off them.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [suspend-an-account.md](../how-to/suspend-an-account.md#put-a-name-or-picture-back)
- **Example:** `oh account restore 0123456789abcdef0123456789abcdef --apply`

### oh account delete

```bash
oh account delete <account> [--apply]
```

Deletes an account's data on its owner's request: its name off its kept games, and every row the service keeps for it. Refuses an account whose subscription is still paid up: cancel it first.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, (Workers R2 Storage Edit)
- **How-to:** [delete-an-accounts-data.md](../how-to/delete-an-accounts-data.md)
- **Example:** `oh account delete 0123456789abcdef0123456789abcdef --apply`

### oh account hold

```bash
oh account hold <account> [--apply] [--ref <ref>]
```

Holds an account's data as it is after a report the law requires, such as one of child sexual abuse material to NCMEC: a year at the least, during which nothing deletes it or puts back what was taken off it. --ref is the report's number. A deletion its owner asks for meanwhile is noted, and done once the hold is released.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [handle-abuse-material.md](../how-to/handle-abuse-material.md#take-it-down-and-hold-the-account)
- **Example:** `oh account hold 0123456789abcdef0123456789abcdef --ref 123456789 --apply`

### oh account release

```bash
oh account release <account> [--apply]
```

Releases a legal hold once its year is out, and says whether the account's owner asked meanwhile for its data to be deleted.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [handle-abuse-material.md](../how-to/handle-abuse-material.md#release-the-hold)
- **Example:** `oh account release 0123456789abcdef0123456789abcdef --apply`

## Terms and price

Changing the terms of use, the privacy policy or the price, as site/ledger.json records them, and telling subscribers.

### oh terms status

```bash
oh terms status
```

Says, for the terms and the privacy policy, the newest entry in the ledger, whether this checkout matches it, which version the site serves, what a deploy would publish, and how many web subscribers were told of each change. Without Cloudflare credentials, how many were told is left out.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [change-the-terms.md](../how-to/change-the-terms.md#check-where-a-change-stands)
- **Example:** `oh terms status`

### oh terms record

```bash
oh terms record <document> [--apply] [--change <change>] [--date <date>]
```

Writes the ledger entry for a change this checkout makes to the terms or the privacy policy: its day, its fingerprint, the kind of change and, for the terms, the price. --change is `minor` (nobody's rights or duties change), `material` or `price`; --date is the day it is to go live, today unless given. While the branch's own newest entry is not on main yet, it is brought up to date instead. The summary in each language is written by hand afterwards.

- **Needs:** nothing but this checkout
- **How-to:** [change-the-terms.md](../how-to/change-the-terms.md#record-the-change)
- **Example:** `oh terms record terms --change material --apply`

### oh terms notified

```bash
oh terms notified <document> [--apply] [--on <on>]
```

Records the day the App Store and Google Play were told of the document's newest material change. --on is that day, today unless given. A production deploy refuses a material change the stores were not told of while either app is in its store.

- **Needs:** nothing but this checkout
- **How-to:** [change-the-terms.md](../how-to/change-the-terms.md#tell-the-app-stores)
- **Example:** `oh terms notified terms --on 2026-11-02 --apply`

### oh terms eula

```bash
oh terms eula
```

Prints the terms, in English, as plain text: the licence agreement App Store Connect takes for the app. Paste it into App Store Connect whenever the terms change while the app is in the App Store.

- **Needs:** nothing but this checkout
- **How-to:** [change-the-terms.md](../how-to/change-the-terms.md#update-the-licence-agreement-in-the-app-store)
- **Example:** `oh terms eula`

### oh terms notify

```bash
oh terms notify [--apply]
```

Emails every web subscriber a published change that matters to them, once: each material or price change of the last 60 days, to the subscriptions begun before it. No deploy runs it: run it once the change is live, and again when a notice did not go; it tells only those it has not. A change to the terms applies to a subscription from its first renewal at least 30 days after its email.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `STRIPE_API_KEY`
- **How-to:** [change-the-terms.md](../how-to/change-the-terms.md#tell-subscribers)
- **Example:** `oh terms notify --apply`

## Releasing

Putting the relay worker and the site into production, and checking production afterwards.

### oh deploy relay

```bash
oh deploy relay [--apply]
```

Deploys the relay worker, and the backup jurors' container with it, from main. Needs Docker running, Dart and Cargo. Refused unless HEAD is origin/main with nothing uncommitted.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [deploy.md](../how-to/deploy.md)
- **Example:** `oh deploy relay --apply`

### oh deploy site

```bash
oh deploy site [--apply] [--label <label>]
```

Builds and publishes the site, the web app and the service's handlers: to production from main, or to a preview. The label names the preview; it is `main` (production) on main and `dev` elsewhere unless given. Production is refused unless HEAD is origin/main with nothing uncommitted, and unless the terms and the privacy policy are as the ledger says, with what a change needs done (oh terms status). It emails nobody: a change that matters to subscribers is emailed to them by oh terms notify.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, STRIPE_API_KEY (to publish a change subscribers are told of)
- **How-to:** [deploy.md](../how-to/deploy.md)
- **Example:** `oh deploy site --label my-change --apply`

### oh deploy all

```bash
oh deploy all [--apply]
```

Deploys production in the order that keeps devices playing: the relay, then the site.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, STRIPE_API_KEY (to publish a change subscribers are told of)
- **How-to:** [deploy.md](../how-to/deploy.md)
- **Example:** `oh deploy all --apply`

### oh deploy prune

```bash
oh deploy prune [--apply] [--keep <keep>]
```

Deletes old preview deployments, keeping the newest few (5 unless --keep says) and anything live.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [deploy.md](../how-to/deploy.md#sweep-up-old-previews)
- **Example:** `oh deploy prune --keep 5 --apply`

### oh verify

```bash
oh verify
```

Checks production: the live build is origin/main, the service is healthy, the relay and the order route answer, every web subscriber was emailed each published change that matters to them, and Cloudflare, Stripe and New Relic match their definitions. A check whose credentials are not set is skipped and said so.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `STRIPE_API_KEY`, `NEW_RELIC_API_KEY`, `NEW_RELIC_ACCOUNT_ID`, `NEW_RELIC_REGION`
- **How-to:** [deploy.md](../how-to/deploy.md#check-it-worked)
- **Example:** `oh verify`

## Setting up

What the deployment is made of: its accounts' definitions, its run-time rows, its secrets, and the phone builds.

### oh infra

```bash
oh infra [--apply] [--only <only>]
```

Makes Cloudflare, Stripe and New Relic match their definitions (infra/, observability/), or says how they differ. --only takes `cloudflare`, `stripe` or `newrelic`.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `STRIPE_API_KEY`, `NEW_RELIC_API_KEY`, `NEW_RELIC_ACCOUNT_ID`, `NEW_RELIC_REGION`
- **How-to:** [apply-infrastructure.md](../how-to/apply-infrastructure.md)
- **Example:** `oh infra --only stripe`

### oh config get

```bash
oh config get <row>
```

Prints a run-time row as the store holds it.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [change-remote-config.md](../how-to/change-remote-config.md)
- **Example:** `oh config get app`

### oh config set

```bash
oh config set <row> <file> [--apply]
```

Replaces a run-time row with a file, checked first as the service checks it. A field that would fail its check stops the write, so a typo is caught rather than quietly left at its default. A field left out goes back to its default.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [change-remote-config.md](../how-to/change-remote-config.md)
- **Example:** `oh config set app config-app.json --apply`

### oh config clear

```bash
oh config clear <row> [--apply]
```

Deletes a run-time row, so every field goes back to its default.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [change-remote-config.md](../how-to/change-remote-config.md)
- **Example:** `oh config clear app --apply`

### oh secret set

```bash
oh secret set <name> [--apply]
```

Sets a secret wherever infra/cloudflare.mjs says it lives, from what you type (not shown) or pipe in.

- **Needs:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- **How-to:** [rotate-the-service-key.md](../how-to/rotate-the-service-key.md)
- **Example:** `oh secret set OH_SERVICE_SECRET --apply`

### oh key mint

```bash
oh key mint
```

Makes a new service key pair and prints both halves once, keeping neither.

- **Needs:** Dart, and dart pub get in service/
- **How-to:** [rotate-the-service-key.md](../how-to/rotate-the-service-key.md)
- **Example:** `oh key mint`

### oh phone

```bash
oh phone <platform> [-- <flutter build options>]
```

Builds a store release of the app, with the deal's native libraries and what config/openhearts.json names. Anything after `--` goes to flutter build as it is.

- **Needs:** Xcode on a Mac (iOS), or the Android NDK and app/android/key.properties (Android)
- **How-to:** [cut-a-phone-release.md](../how-to/cut-a-phone-release.md)
- **Example:** `oh phone android`
