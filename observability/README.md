# Observability

Open Hearts' monitoring in New Relic, defined here and applied by script
rather than set up by hand.

- `monitoring.mjs` — what is watched and who is told: ping monitors on
  the site, the app, `/api/health` and the relay, once a minute from
  two places; an alert when one fails from both for two minutes; an
  email to the address in `OH_ALERT_EMAIL`.
- The **Open Hearts: web** browser app (New Relic Browser, real-user
  monitoring): errors, load times and the service's calls from people's
  own browsers, with no cookies, session replay or session traces.
  `apply.mjs` writes its loader to `app/web/observability.js`, which
  runs only on openhearts.game. New Relic cannot rename a browser app,
  so changing its name in the definition deletes it and makes it again.
- `apply.mjs` — makes the account match. A dry run by default:

      node observability/apply.mjs            # what would change
      node observability/apply.mjs --apply    # change it

  Needs `NEW_RELIC_API_KEY` (a User key), `NEW_RELIC_ACCOUNT_ID`,
  `NEW_RELIC_REGION` and `OH_ALERT_EMAIL` in the environment.

The account may hold other apps. On New Relic's free edition an
organization has one account, so this app keeps to its own within it:
everything is named `Open Hearts: …`, tagged `app: open-hearts`, and
gathered in the **Open Hearts** workload, with its own alert policy,
email destination and workflow. The script reads and writes only what
carries that tag or name, and deletes a monitor of ours only when it
has left the definition.
