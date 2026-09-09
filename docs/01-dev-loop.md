# 01 — The development loop

The constraint this repo is shaped around: **development is driven from a
phone.** Not "works on a phone" — driven from one. That rules out
anything whose feedback arrives in a terminal.

## What happens on every commit

```
./deploy.sh
```

1. Copies `site/` into `build/publish/`.
2. Builds the Flutter web app with `--base-href /play/` into
   `build/publish/play/`.
3. Writes `build/publish/play/build-info.json` stamped with the short
   commit sha.
4. Uploads the lot to Cloudflare Pages as a **branch deployment**.

Cloudflare gives every branch a stable alias host, so the URL does not
change between commits:

| | |
|---|---|
| Working branches | `https://dev.open-hearts.pages.dev/play` |
| `main` (production) | `https://open-hearts.pages.dev/play` — and the custom domain |

The label defaults to `dev` on any branch other than `main`. One short
host, bookmarkable, always the last push. Pass a label to override:
`./deploy.sh my-experiment` publishes to
`https://my-experiment.open-hearts.pages.dev`.

About 45 seconds end to end, most of it the Flutter build. Uploads are
content-addressed, so a redeploy typically re-uploads under ten files.

## Knowing which build you are looking at

A phone keeps a page alive for days. Without help, "did my change land?"
is a hard refresh and a guess. So:

- the running build's sha is stamped in the corner of the table;
- `deploy.sh` passes `--dart-define=UPDATE_CHECK=on`, and only deploy.sh
  does. The app then fetches `build-info.json` at launch and on every
  return to the foreground, and shows a tap-to-reload pill when the
  published sha differs from its own;
- `_headers` marks the entry points `no-store` so a cached bootstrap
  cannot lie about this.

`UPDATE_CHECK` is passed explicitly rather than inferred from a
real-looking build tag. Inferring it turns the pill on in CI, where it
floats over the widget tests and eats their taps.

A build stamped `abc1234+` was deployed from a dirty tree: it contains
work newer than the commit it names.

## Credentials

`deploy.sh` needs `CLOUDFLARE_TOKEN` (Pages: Edit) and
`CLOUDFLARE_ACCOUNT_ID`. Nothing else, and no `wrangler.toml` — the
project name is in the script.

## Domains

`openhearts.game` and `openhearts.lol` are not attached yet; the API
token used by `deploy.sh` is scoped to Pages and cannot touch DNS. Both
steps are one-time, in the Cloudflare dashboard:

**`openhearts.game` → the site.** Add the zone, then Workers & Pages →
`open-hearts` → Custom domains → add `openhearts.game` and
`www.openhearts.game`. Production (the `main` branch) serves it, so
`/play` comes along for free.

**`openhearts.lol` → redirect.** Add the zone. Add a proxied DNS record
so requests reach the edge at all (an `AAAA` for `@` to `100::` with the
orange cloud on is the conventional placeholder). Then Rules → Redirect
Rules: match hostname `openhearts.lol`, redirect to
`concat("https://openhearts.game", http.request.uri.path)`, 301,
preserve query string. Free, no Worker, no origin.

Keep `*.pages.dev` working after that: the branch aliases are the dev
loop, and production keeping its `pages.dev` host costs nothing.
