# Deploy the site, app and service

Use this guide to publish the site, the web app and the service's handlers to Cloudflare Pages, and the relay worker to Cloudflare Workers.

`./oh deploy site` publishes the site, the app and the handlers in one upload to the Pages project `open-hearts`, through `deploy.sh`. `./oh deploy relay` deploys the relay worker (`open-hearts-relay`, which also runs the `Household` object and the house) from `service/do/wrangler.toml`. Each says first what it would do and what stands in the way, and does it only with `--apply` ([the oh command](../reference/oh.md)).

## Before you begin

- Production is built from `main` as it was reviewed: `HEAD` must be `origin/main` as it can be fetched now, with nothing uncommitted and no untracked file. For the site, no file git ignores may be one it would publish: a page in `site/pages`, a module in `service/functions` (not a test or its fixtures), or any file in `site/public` or `app/web` but a `.DS_Store` or one in a `node_modules` or `.git` folder, which Wrangler leaves out. `deploy.sh` and the relay's build step check this themselves (`ops/gate.mjs`), so it holds whether or not you deploy through `oh`. A preview, and the preview relay, can be deployed from any branch you have read: deploying one runs that branch's own `oh`, `deploy.sh`, builds and `service/do/wrangler.toml` on your machine, with your Cloudflare token, which can also deploy production ([security model](../explanation/security-model.md#secrets)).
- A production deploy of the site also holds the terms and the privacy policy to `site/ledger.json`. It emails nobody: after publishing a change that matters to subscribers, [tell them](change-the-terms.md#tell-subscribers) yourself. See [Change the terms](change-the-terms.md#publish-it).
- Make sure the commit passes CI, or run `./check.sh full`.
- Install Node, git and Flutter. CI pins the Flutter version in `.github/workflows/ci.yml`. The web build needs no Rust: the wasm is committed.
- Wrangler is run from `ops/wrangler`, at the version its `package.json` names and with its whole dependency tree locked in `package-lock.json`. The first deploy installs it there with `npm ci`, as it does again whenever the lockfile changes. Of the credentials `oh` reads, it passes Wrangler and `deploy.sh`, and the builds they run, Cloudflare's alone: never `STRIPE_API_KEY` or New Relic's.
- To deploy the relay, you also need a linux/amd64 machine with Dart, Cargo (CI pins the Rust version in `.github/workflows/ci.yml`) and Docker running. Wrangler builds the house's image from `service/bench/Dockerfile` with binaries built on your machine (`service/bench/build.sh`). Run `dart pub get` in `service/` once. `./oh deploy relay` says which of these is missing.
- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. For what else the scripts read, see [environment variables](../reference/configuration.md#deploying-and-operating).
- For production, `serviceKey` must be set in `config/openhearts.json`: `deploy.sh` refuses a production deploy without it. To set it up, see [Mint or rotate the service key](rotate-the-service-key.md).
- For production, `houseKey` must be set in `config/openhearts.json` too, and its secret on the relay worker: `./oh deploy relay` refuses without it. Make both with `./oh house key --apply`, then commit `config/openhearts.json`. Do it with no table playing: a table started under another house's key is one no house serves.

## Deploy production

1. Decide what to deploy. Deploy the site after any change to the site, the app, the handlers or `config/openhearts.json`. Deploy the relay worker as well when anything it is built from has changed:

   - `service/do/`
   - `service/functions/household.mjs` and the modules it imports, since the `Household` object comes from there
   - `config/openhearts.json`, which the relay worker reads when it is deployed
   - `app/web/schnorr.wasm`
   - the house's code: `service/bin/house.dart` and the `packages/` it imports

1. See what would be deployed, and what stands in the way:

   ```bash
   ./oh deploy all
   ```

   Each `not ready:` line is something to put right first.

1. Deploy both, the relay worker first:

   ```bash
   ./oh deploy all --apply
   ```

   The relay goes first because the `Household` object runs in the relay worker. A new site whose handlers ask the object something it does not know yet gets a 400 (`not a household operation`) until the relay is deployed. To deploy only one, use `./oh deploy relay --apply` or `./oh deploy site --apply`. A production site deploy first [deletes old deployments](#sweep-up-old-deployments).

   For the relay, `oh` first runs `wrangler deploy --dry-run`, which runs `service/bench/build.sh` (it builds the deal and Schnorr libraries and compiles the house) and builds the house's image, but uploads nothing. A real deploy uploads the worker, live at once, before it builds the image, so an image that failed to build there would leave the new worker beside the old house. Only once the dry run has built both does `oh` deploy: the build again, the worker, and the house's image built and pushed.

   If the deploy fails after its upload all the same, `oh` puts back the version that served before (`wrangler rollback`), and says so. If it can't tell which version served, it rolls nothing back: check with `../../ops/wrangler/wrangler deployments status` from `service/do`.

## Deploy a preview

From any branch you have read (see [Before you begin](#before-you-begin)):

```bash
./oh deploy site --label my-change --apply
```

Without `--label`, the label is `dev` on a working branch. A preview is published to `https://<label>.open-hearts.pages.dev/`, and is not held to the checks production is.

## Play live on a preview

A preview plays live too, on the preview relay, with the people you invite. Previews are a deployment of their own:

- their own store, and their own relay worker, `open-hearts-relay-preview` at `relay-preview.openhearts.game`, with its own households and its own house
- secrets of their own, none of them production's, since a preview runs whatever branch was deployed to it. Nothing a preview signs is good in production, and a preview takes nothing production signed.
- no email: a preview sends none
- no profile pictures at its tables. Pictures are checked against known images before anyone is shown one, and only production checks them. Your own picture still shows on your own device.

There is one preview relay for every preview. It runs the branch it was last deployed from, so deploy it again from the branch you're trying when that branch changes the relay.

### Set it up once

1. Make the secrets previews keep for themselves:

   ```bash
   ./oh preview secrets --apply
   ```

   It sets the previews' service secret and the key their sign-ins are stored under (`OH_ID_HMAC`) on the Pages project's preview environment, and the preview relay's house secret, and shows none of them. It writes the public keys to `config/openhearts.json` as `preview.serviceKey` and `preview.houseKey`: commit them. A sign-in linked on a preview before has to be linked again.

1. Deploy the preview relay, from the branch you're on:

   ```bash
   ./oh deploy relay --preview --apply
   ```

   It needs what a relay deploy needs ([Before you begin](#before-you-begin)), and it refuses until `config/openhearts.json` has the previews' key.

1. Bind the Pages project's preview environment to the preview relay's households, and mark it as a preview (`OH_DEPLOYMENT`):

   ```bash
   ./oh infra --apply
   ```

1. Deploy each preview again (`./oh deploy site --label <label> --apply`). A preview builds the previews' key into its app, and points its app at the preview relay.

To replace the previews' secrets, run `./oh preview secrets --apply` again, commit, and deploy the preview relay and the previews again.

### Invite someone to play

```bash
./oh preview invite --apply
```

It makes an account on the previews' store and prints one of its backup codes. Nobody buys anything on a preview. On the device, open the preview's app (`https://<label>.open-hearts.pages.dev/play/`), choose **Activate subscription** from the menu, and enter the code. The account plays live on every preview for a year.

Give each person their own invitation, since an account plays on one device at a time. The account's other four codes are shown on any of its devices, to bring another device of the same person in.

## Sweep up old deployments

Cloudflare keeps every upload as a deployment until it is deleted. A production deploy of the site deletes the old ones before it publishes. It keeps:

- the newest five previews, and the newest five previews that succeeded
- the newest three production deployments, and the newest three that succeeded, so there is always something to roll back to
- every deployment that is live: production's on its domains, and the newest of each preview branch on its branch's address

Because it runs before publishing, the deployment being replaced is still live at that point, so it is kept. After the deploy you can roll back to it. If the cleanup fails, the deploy says so and goes on. A preview's deploy deletes nothing.

To clean up without deploying, see what would go first:

```bash
./oh deploy prune
```

Then delete them, keeping the newest five previews (or the number you give with `--keep`):

```bash
./oh deploy prune --apply
```

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
