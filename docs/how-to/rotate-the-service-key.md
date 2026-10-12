# Mint or rotate the service key

Use this guide to make the service's signing key pair for a new deployment, or to replace the pair in use with a new one.

The public half is `serviceKey` in `config/openhearts.json`. The secret half is the Pages secret `OH_SERVICE_SECRET`, and it is kept nowhere else.

## Where each half is used

| Part | Holds | Uses it to |
|---|---|---|
| Pages worker (`service/functions/worker.mjs`) | `OH_SERVICE_SECRET`, and `serviceKey` from the deployed config | Sign licences and activations (`serviceSigned`). It signs only when the two halves are a pair, and otherwise answers 503 to `licence` and `activate`. |
| Web app | `serviceKey`, compiled in by `deploy.sh` | Accept a licence or an activation only if this key signed it (`Entitlement` in `app/lib/entitlement.dart`, `InUse` in `app/lib/net/in_use.dart`), and check every seat's licence at a table (`licenceService` in `packages/table/lib/src/licence.dart`). |
| Phone apps | `serviceKey`, compiled in by `build_phone.sh` (`app/tool/defines.mjs`) | The same as the web app. |
| Relay worker (`service/do/worker.mjs`) | `serviceKey` from the config, read when it is deployed | Carry a device only with an activation this key signed (`gate`). |
| Backup jurors (`service/bin/juror.dart`) | The relay worker's key, given to their container when it starts (`wake` in `service/do/bench.mjs`) | Hold every seat to its licence. |

## What a rotation breaks

Every part above checks against exactly one key, so there is no overlap between the old pair and the new one. Read this before you rotate:

- **Devices on the old build lose live play.** A device whose build has the old key keeps its stored licence until that licence's date, but it rejects every licence and activation signed by the new key. Once the relay has the new key, it turns away the device's old activation. Live play stays shut on that device until it runs a build with the new key: for a phone, until it installs the new release; for a web page, until it is reloaded.
- **Devices on the new build get a new licence by themselves.** At start, a build with the new key drops a stored licence signed by the old key, and asks the service for a licence until it answers (`load` and `keepAsking` in `app/lib/entitlement.dart`). A subscriber's device is licensed again at its first start on the new build with a network.
- **Old and new builds cannot sit at one table.** Each side rejects the other's seats as having no licence for their key (`licenceProblem` in `packages/table/lib/src/spec.dart`).
- **Results and records from before the rotation stop checking out in new builds.** Results and records are checked without a date, against the build's one key. In a build with the new key, results published before the rotation no longer count toward ratings (`licensed` in `packages/table/lib/src/results.dart`), and a kept record of a live game played before it fails its check with `seat … has no licence for its key` (`verifyRecord` in `packages/table/lib/src/record.dart`).

## Before you begin

- Install Dart and Node, and run `dart pub get` in `service/`.
- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, and set `WRANGLER_VERSION` as [Deploy the site, app and service](deploy.md#before-you-begin) shows.
- Be ready to deploy both workers ([Deploy the site, app and service](deploy.md)) and to build both phone releases ([Build a phone release](cut-a-phone-release.md)).
- To rotate, start with nothing else waiting to deploy, so that the order below is the only one that matters.
- Run the commands from the repository root.

## Mint the first key pair

1. Mint a pair. The tool prints both halves once and keeps neither:

   ```bash
   (cd service && dart run bin/service_key.dart)
   ```

1. Put the `OH_SERVICE_KEY` value in `config/openhearts.json` as `serviceKey`, and commit the change to `main`.
1. Set the `OH_SERVICE_SECRET` value as a secret on both of the Pages project's environments. Wrangler prompts for the value: paste the secret.

   ```bash
   npx wrangler@"$WRANGLER_VERSION" pages secret put OH_SERVICE_SECRET --project-name open-hearts
   npx wrangler@"$WRANGLER_VERSION" pages secret put OH_SERVICE_SECRET --project-name open-hearts --env preview
   ```

   Do not save the secret anywhere else.

1. Deploy the relay worker and the site from `main`, as [Deploy the site, app and service](deploy.md) shows.
1. Build and release both phone apps, as [Build a phone release](cut-a-phone-release.md) shows.

## Rotate to a new key pair

1. Mint a new pair:

   ```bash
   (cd service && dart run bin/service_key.dart)
   ```

1. Put the new `OH_SERVICE_KEY` value in `config/openhearts.json` as `serviceKey`, and commit the change to `main`. Do not deploy yet.
1. Build both phone releases from this commit and submit them to the stores, but hold their release until the last step. A phone build with the new key can get no licence while the service still signs with the old secret.
1. Set the new `OH_SERVICE_SECRET` value on both of the Pages project's environments. Wrangler prompts for the value: paste the secret.

   ```bash
   npx wrangler@"$WRANGLER_VERSION" pages secret put OH_SERVICE_SECRET --project-name open-hearts
   npx wrangler@"$WRANGLER_VERSION" pages secret put OH_SERVICE_SECRET --project-name open-hearts --env preview
   ```

   A Pages secret reaches only deployments made after it is set, so the live deployment goes on signing with the old pair until the next step.

1. At once, deploy the site from `main`:

   ```bash
   ./deploy.sh
   ```

   From this deployment on, the worker signs licences and activations with the new pair, and the web app checks them with the new key. Devices already connected keep playing on their current activation, which the relay still accepts until it runs out or the relay is deployed.

1. At once, deploy the relay worker:

   ```bash
   (cd service/do && npx wrangler@"$WRANGLER_VERSION" deploy)
   ```

   From this deployment on, the relay carries only devices with an activation signed by the new key. Until it is live, a device that starts afresh gets an activation that the relay refuses, so deploy the relay as soon as the site is live.

   This order is the reverse of the usual one in [Deploy the site, app and service](deploy.md). Deploying the relay first would turn away every device at once, since they all hold activations signed by the old key, until the site was deployed.

   A deploy does not restart the backup jurors' container, which takes `OH_SERVICE_KEY` when it starts. At the next call for a juror, the `Bench` object restarts a running container that was started with anything other than what it would start one with now: the service key, `OH_JUROR_SECRET`, or the relay overrides (`wake` in `service/do/bench.mjs`). The backup jurors check seats against the new key from then on.

1. Release the phone builds in both stores.

## Check it worked

1. Check that both environments have the secret (names only, never values):

   ```bash
   npx wrangler@"$WRANGLER_VERSION" pages secret list --project-name open-hearts
   npx wrangler@"$WRANGLER_VERSION" pages secret list --project-name open-hearts --env preview
   ```

1. Check that the published web build is the commit with the new key:

   ```bash
   curl -s https://play.openhearts.game/build-info.json
   ```

1. On a subscribed device with the new build, reload or restart the app. Live play is open on the front door, which means the device holds a licence that the new key signed. Join a live table, which means the relay accepted the device's new activation.

## Learn more

- [The service](../explanation/service.md#licence): what a licence and an activation are, and why a build without the key has live play shut.
- [Security model](../explanation/security-model.md#licences): why the key is compiled into every build.
