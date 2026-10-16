# Change what every device gets: remote config and service settings

Use this guide to change, without a release, what every device is told (remote config), the numbers the service runs by (service settings), the relay's limits (relay settings), or the operator's alerts.

Remote config, service settings and relay settings are each one JSON row in the production store, `OH_STORE`:

| Row | Read by | Fields |
|---|---|---|
| `config\|app` | Every device, through `/api/config` | [Remote config](../reference/configuration.md#remote-config) |
| `config\|service` | The Pages worker and the `Household` object, never served | [Service settings](../reference/configuration.md#service-settings) |
| `config\|relay` | The relay's presence object (tag `online`), never served | [Relay settings](../reference/configuration.md#relay-settings) |

## Before you begin

- Install Node, and export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
- Run the commands from the repository root. `./oh config` reads and writes the production namespace that `service/do/wrangler.toml` binds as `OH_STORE`, which is the one the Pages project's production environment uses ([the oh command](../reference/oh.md)).

## Change a row

1. Read the row as it is now:

   ```bash
   ./oh config get app
   ```

   `no config|app row` means every field has its default.

1. Write the whole row, with your change, to a file such as `config-app.json`. A row is replaced whole, so keep every field you want to keep: a field you leave out goes back to its default. For example, to close live play and say why on the front door:

   ```json
   {
     "live": false,
     "banner": {
       "id": "relays-down-1",
       "level": "warn",
       "text": { "en": "Live play is down until 18:00 UTC.", "de": "Live-Spiel bis 18 Uhr UTC aus." }
     }
   }
   ```

1. Check the file as the service will read it, and see what it would replace:

   ```bash
   ./oh config set app config-app.json
   ```

   A field that would fail its check, such as a misspelt name or a value out of bounds, is named, and nothing is written: the service would leave it at its default, so the change would quietly do nothing. A field the service takes but fills in, such as a banner's `level`, is shown as it will be taken.

1. Put the file in the store as the row:

   ```bash
   ./oh config set app config-app.json --apply
   ```

   For service settings or relay settings, use `service` or `relay` in place of `app`.

1. To go back to the defaults, delete the row:

   ```bash
   ./oh config clear app --apply
   ```

## Turn the operator's alerts off or on

The alerts are not a row. They are `alerts.subscribed` and `alerts.waiting` in `config/openhearts.json` (see [`config/openhearts.json`](../reference/configuration.md#configopenheartsjson)).

1. Set the flag to `false` (off) or `true` (on), and commit the change to `main`.
1. Deploy the site, as [Deploy the site, app and service](deploy.md) shows. The Pages worker decides whether to send an alert.

## Check it worked

1. For remote config, ask the handler what it serves. A field that passed its check appears with your value. One that failed appears at its default or, for `table` and each wait, is left out, and the app uses its own value ([remote config](../reference/configuration.md#remote-config)).

   ```bash
   curl -s https://play.openhearts.game/api/config
   ```

   The answer may be cached for up to a minute. Devices take the change at their next start, or when they next ask while open (`configEveryMin`, see [Waits](../reference/configuration.md#waits)).

1. For service settings and relay settings, read the row back with `./oh config get service` or `./oh config get relay`. Nothing serves them:

   - The Pages worker and the `Household` object read `config|service` at most once a minute in each isolate.
   - The presence object reads `config|relay` when it is built after it wakes, so while it stays awake it keeps its old limits.

## Learn more

- [The service](../explanation/service.md#remote-config): why some things change for every device at once, and why the bounds stop where they do.
