# Deploy the site, app and service

Use this guide to publish the site, the web app and the service's handlers to Cloudflare Pages, and the relay worker to Cloudflare Workers.

`deploy.sh` publishes the site, the app and the handlers in one upload to the Pages project `open-hearts`. The relay worker (`open-hearts-relay`, which also runs the `Household` object and the backup jurors) deploys separately, from `service/do/wrangler.toml`.

## Before you begin

- For a production deploy, check out `main` at the commit you want to publish. On `main`, `deploy.sh` publishes to the `main` branch label, which is production. On any other branch it publishes a preview.
- Commit your work first. A build made from a tree with uncommitted changes names itself with a `+` after its commit.
- Make sure the commit passes CI, or run `./check.sh full`.
- Install Node, git, Python 3 (for `--prune`) and Flutter. CI pins the Flutter version in `.github/workflows/ci.yml`. The web build needs no Rust: the wasm is committed.
- To deploy the relay, you also need a linux/amd64 machine with Dart, Cargo (CI pins the Rust version in `.github/workflows/ci.yml`) and Docker running. Wrangler builds the backup jurors' image from `service/bench/Dockerfile` with binaries built on your machine (`service/bench/build.sh`). Run `dart pub get` in `service/` once.
- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. For what else the scripts read, see [environment variables](../reference/configuration.md#deploying-and-operating).
- For production, `serviceKey` must be set in `config/openhearts.json`: `deploy.sh` refuses a production deploy without it. To set it up, see [Mint or rotate the service key](rotate-the-service-key.md).
- Set the Wrangler version that the repository pins (`WRANGLER_VERSION` in `deploy.sh`) in your shell, from the repository root:

  ```bash
  export WRANGLER_VERSION=$(sed -n 's/^WRANGLER_VERSION=//p' deploy.sh)
  ```

## Deploy

1. Decide what to deploy. Deploy the site after any change to the site, the app, the handlers or `config/openhearts.json`. Deploy the relay worker as well when anything it is built from has changed:

   - `service/do/`
   - `service/functions/household.mjs` and the modules it imports, since the `Household` object comes from there
   - `config/openhearts.json`, which the relay worker reads when it is deployed
   - `app/web/schnorr.wasm`
   - the backup jurors' code: `service/bin/juror.dart` and the `packages/` it imports

1. If you deploy both, deploy the relay worker first:

   ```bash
   (cd service/do && npx wrangler@"$WRANGLER_VERSION" deploy)
   ```

   Wrangler runs `service/bench/build.sh` first, which builds the deal and Schnorr libraries and compiles the backup juror, and then builds and uploads the jurors' image.

   The relay goes first because the `Household` object runs in the relay worker. A new site whose handlers ask the object something it does not know yet gets a 400 (`not a household operation`) until the relay is deployed.

1. From the repository root, deploy the site, the app and the handlers:

   ```bash
   ./deploy.sh
   ```

   To publish a preview under a label of your own instead of the default (`dev` on a working branch), name it:

   ```bash
   ./deploy.sh my-label
   ```

1. Optional: sweep up old preview deployments. See what would go first:

   ```bash
   ./deploy.sh --prune -n
   ```

   Then delete them, keeping the newest five previews (or the number you give):

   ```bash
   ./deploy.sh --prune
   ```

   Production always keeps its live deployment and the two before it.

## Check it worked

1. `deploy.sh` ends by printing the site's and the app's addresses on `<label>.open-hearts.pages.dev`, and for production, `https://play.openhearts.game/`.
1. Check that the published build is your commit. The `build` field must match `git rev-parse --short HEAD`:

   ```bash
   curl -s https://play.openhearts.game/build-info.json
   ```

   For a preview, ask `https://<label>.open-hearts.pages.dev/play/build-info.json`. The app's About page shows the same commit and date.

1. For production, check that the service can sell: `ok` is `true` when the store (`OH_STORE`) and Stripe both answer.

   ```bash
   curl -s https://play.openhearts.game/api/health
   ```

1. If you deployed the relay worker, check that it answers, and that the live worker matches its definition:

   ```bash
   curl -s https://relay.openhearts.game/
   node infra/apply.mjs --only cloudflare
   ```

   The first prints `open hearts relay: a relay lives at /<tag>`. The second prints an `ok` line for the relay worker, or a `by hand:` line for each difference.

## Learn more

- [How a change reaches a phone](../explanation/dev-loop.md): one upload routed by host, and how a running build knows which commit it is.
- [The service](../explanation/service.md#deployment): what each worker holds, and why the relay deploys first.
- [Make Cloudflare, Stripe and New Relic match their definitions](apply-infrastructure.md), for everything that is not a deploy.
