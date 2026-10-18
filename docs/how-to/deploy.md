# Deploy the site, app and service

Use this guide to publish the site, the web app and the service's handlers to Cloudflare Pages, and the relay worker to Cloudflare Workers.

`./oh deploy site` publishes the site, the app and the handlers in one upload to the Pages project `open-hearts`, through `deploy.sh`. `./oh deploy relay` deploys the relay worker (`open-hearts-relay`, which also runs the `Household` object and the backup jurors) from `service/do/wrangler.toml`. Each says first what it would do and what stands in the way, and does it only with `--apply` ([the oh command](../reference/oh.md)).

## Before you begin

- Production is built from `main` as it was reviewed: `HEAD` must be `origin/main`, with nothing uncommitted. `deploy.sh` and the relay's build step check this themselves (`ops/gate.mjs`), so it holds whether or not you deploy through `oh`. A preview can be deployed from any branch.
- A production deploy of the site also holds the terms and the privacy policy to `site/ledger.json`. It emails nobody: after publishing a change that matters to subscribers, [tell them](change-the-terms.md#tell-subscribers) yourself. See [Change the terms](change-the-terms.md#publish-it).
- Make sure the commit passes CI, or run `./check.sh full`.
- Install Node, git, Python 3 (for pruning) and Flutter. CI pins the Flutter version in `.github/workflows/ci.yml`. The web build needs no Rust: the wasm is committed.
- To deploy the relay, you also need a linux/amd64 machine with Dart, Cargo (CI pins the Rust version in `.github/workflows/ci.yml`) and Docker running. Wrangler builds the backup jurors' image from `service/bench/Dockerfile` with binaries built on your machine (`service/bench/build.sh`). Run `dart pub get` in `service/` once. `./oh deploy relay` says which of these is missing.
- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. For what else the scripts read, see [environment variables](../reference/configuration.md#deploying-and-operating).
- For production, `serviceKey` must be set in `config/openhearts.json`: `deploy.sh` refuses a production deploy without it. To set it up, see [Mint or rotate the service key](rotate-the-service-key.md).

## Deploy production

1. Decide what to deploy. Deploy the site after any change to the site, the app, the handlers or `config/openhearts.json`. Deploy the relay worker as well when anything it is built from has changed:

   - `service/do/`
   - `service/functions/household.mjs` and the modules it imports, since the `Household` object comes from there
   - `config/openhearts.json`, which the relay worker reads when it is deployed
   - `app/web/schnorr.wasm`
   - the backup jurors' code: `service/bin/juror.dart` and the `packages/` it imports

1. See what would be deployed, and what stands in the way:

   ```bash
   ./oh deploy all
   ```

   Each `not ready:` line is something to put right first.

1. Deploy both, the relay worker first:

   ```bash
   ./oh deploy all --apply
   ```

   The relay goes first because the `Household` object runs in the relay worker. A new site whose handlers ask the object something it does not know yet gets a 400 (`not a household operation`) until the relay is deployed. To deploy only one, use `./oh deploy relay --apply` or `./oh deploy site --apply`.

   For the relay, Wrangler runs `service/bench/build.sh` first, which builds the deal and Schnorr libraries and compiles the backup juror, and then builds and uploads the jurors' image.

## Deploy a preview

From any branch:

```bash
./oh deploy site --label my-change --apply
```

Without `--label`, the label is `dev` on a working branch. A preview is published to `https://<label>.open-hearts.pages.dev/`, and is not held to the checks production is.

## Sweep up old previews

Every upload is a deployment Cloudflare keeps for ever. See what would go first:

```bash
./oh deploy prune
```

Then delete them, keeping the newest five previews (or the number you give with `--keep`):

```bash
./oh deploy prune --apply
```

Production always keeps its live deployment and the two before it.

## Check it worked

1. The site deploy ends by printing the site's and the app's addresses on `<label>.open-hearts.pages.dev`, and for production, `https://play.openhearts.game/`.
1. Check production:

   ```bash
   ./oh verify
   ```

   It checks that the live build is `origin/main`, that the service can sell (its health is `ok` when the store and Stripe both answer), that the relay and the order route answer, that Link sells a checkout (it makes one and expires it at once), that every web subscriber was emailed each published change that matters to them ([tell subscribers](change-the-terms.md#tell-subscribers)), and that Cloudflare, Stripe and New Relic match their definitions. Each check prints `ok` or `FAILED` with what it found; a check whose credentials aren't set is skipped and said so.

   For a preview, ask `https://<label>.open-hearts.pages.dev/play/build-info.json`. The app's About page shows the same commit and date.

## Learn more

- [How a change reaches a phone](../explanation/dev-loop.md): one upload routed by host, and how a running build knows which commit it is.
- [The service](../explanation/service.md#deployment): what each worker holds, and why the relay deploys first.
- [Make Cloudflare, Stripe and New Relic match their definitions](apply-infrastructure.md), for everything that is not a deploy.
