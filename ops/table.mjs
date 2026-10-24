// `oh table <id>`: what the backup jurors, the relay and the device each
// said of one table, in one timeline (docs/how-to/look-into-a-lost-game.md).
//
// Each side writes its own account and keeps it where it runs. The
// backup jurors' traces are their container's output, every line of a
// table's headed by the first eight of its id (packages/table,
// juror_duty.dart). The relay says each socket's coming and going, and
// the backup jurors' object what it did with them, as lines of JSON
// naming the table the same way (service/do/relay.mjs, socketLine;
// bench.mjs). All three are in Workers Logs. A device that lost a game,
// or whose line was down for long, tells New Relic, with what it saw
// (app/lib/net/report_error.dart, reportLine). Nothing here names a
// person: the jurors' traces hold keys by their first four characters,
// as they always have, and nothing else holds any.

import { Failed, Usage, need } from './env.mjs';

/// How many events one query of Workers Logs returns at most; a window
/// that fills it is split in two and asked again.
const PAGE = 2000;

/// The Workers Logs events in [from, to) in [dataset] that [filter]
/// picks, oldest first: halved and asked again where a window is full,
/// down to a minute. A line of text is found by what its message holds;
/// a line of JSON has no message, its fields being kept as fields, and
/// is found by one of them.
async function logs(ctx, { token, account }, dataset, filter, from, to) {
  const res = await ctx.fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/workers/observability/telemetry/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      queryId: 'oh-table',
      timeframe: { from, to },
      view: 'events',
      limit: PAGE,
      parameters: { datasets: [dataset], filters: [{ type: 'string', ...filter }] },
    }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || !body?.success) throw new Failed(`Workers Logs (${dataset}) said ${res.status}: ${JSON.stringify(body?.errors ?? body)}`);
  const events = body.result?.events?.events ?? [];
  if (events.length >= PAGE && to - from > 60000) {
    const mid = from + Math.floor((to - from) / 2);
    return [...(await logs(ctx, { token, account }, dataset, filter, from, mid)), ...(await logs(ctx, { token, account }, dataset, filter, mid, to))];
  }
  if (events.length >= PAGE) ctx.warn(`${dataset}: more than ${PAGE} lines in the minute from ${stamp(from)}; the rest are not shown`);
  return events;
}

/// A line of the relay's or the backup jurors' object, as it was said.
function said(event) {
  const s = event.source ?? {};
  if (typeof s.relay === 'string') {
    const how = s.code === undefined ? '' : ` code ${s.code}${s.clean ? '' : ' unclean'}`;
    return { from: 'relay', text: `socket ${s.relay} as ${s.as}${how}${s.why ? ` (${s.why})` : ''}${s.openS === undefined ? '' : `, open ${s.openS} s`}; ${s.sockets} on the tag` };
  }
  if (typeof s.bench === 'string') {
    const rest = Object.entries(s).filter(([k]) => k !== 'bench' && k !== 'table' && !k.startsWith('$')).map(([k, v]) => `${k} ${v}`);
    return { from: 'bench', text: [s.bench, ...rest].join(', ') };
  }
  return { from: 'relay', text: event.$metadata?.message ?? JSON.stringify(s) };
}

/// The device's own reports of the table, from New Relic: a game lost,
/// or a line down for long. Null, said, where there are no credentials.
async function reports(ctx, short, days) {
  const env = ctx.env;
  if (!env.NEW_RELIC_API_KEY || !env.NEW_RELIC_ACCOUNT_ID) {
    ctx.log('  the device: not asked (needs NEW_RELIC_API_KEY and NEW_RELIC_ACCOUNT_ID)');
    return [];
  }
  const endpoint = env.NEW_RELIC_REGION === 'EU' ? 'https://api.eu.newrelic.com/graphql' : 'https://api.newrelic.com/graphql';
  const nrql = `SELECT timestamp, errorMessage, seen, line, build FROM JavaScriptError WHERE \`table\` = '${short}' SINCE ${days} days ago LIMIT 100`;
  const res = await ctx.fetch(endpoint, {
    method: 'POST',
    headers: { 'API-Key': env.NEW_RELIC_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      query: 'query($a: Int!, $q: Nrql!) { actor { account(id: $a) { nrql(query: $q) { results } } } }',
      variables: { a: Number(env.NEW_RELIC_ACCOUNT_ID), q: nrql },
    }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || body?.errors) throw new Failed(`New Relic said ${res.status}: ${JSON.stringify(body?.errors ?? body)}`);
  return (body?.data?.actor?.account?.nrql?.results ?? []).map((r) => ({
    at: r.timestamp,
    from: 'device',
    text: `${r.errorMessage}: ${r.seen ?? ''}${r.line ? `; ${r.line}` : ''}${r.build ? ` (build ${r.build})` : ''}`,
  }));
}

const stamp = (ms) => new Date(ms).toISOString().replace('T', ' ').replace('Z', '');

export async function table(ctx, { args, flags }) {
  const id = args.table ?? '';
  if (!/^[0-9a-f]{8}([0-9a-f]{24})?$/.test(id)) throw new Usage('name the table: its id (32 hex characters, the end of /table/<id>), or its first eight');
  const short = id.slice(0, 8);
  const days = flags.days === undefined ? 3 : Number(flags.days);
  if (!Number.isInteger(days) || days < 1 || days > 30) throw new Usage('--days takes a whole number of days, 1 to 30');
  const [token, account] = need(ctx.env, 'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID');
  const to = ctx.now();
  const from = to - days * 24 * 60 * 60 * 1000;
  ctx.log(`table ${short}, the last ${days} day(s):`);
  const jurors = (await logs(ctx, { token, account }, 'containers', { key: '$metadata.message', operation: 'includes', value: short }, from, to)).map((e) => ({
    at: e.timestamp,
    from: 'jurors',
    text: e.$metadata?.message ?? e.source?.message ?? '',
  }));
  // The relay's lines name the table as `tag`, the backup jurors'
  // object's as `table` (service/do/relay.mjs, socketLine; bench.mjs).
  const tag = `table:${short}`;
  const objects = [
    ...(await logs(ctx, { token, account }, 'cloudflare-workers', { key: 'tag', operation: 'eq', value: tag }, from, to)),
    ...(await logs(ctx, { token, account }, 'cloudflare-workers', { key: 'table', operation: 'eq', value: tag }, from, to)),
  ].map((e) => ({ at: e.timestamp, ...said(e) }));
  const device = await reports(ctx, short, days);
  const rows = [...jurors, ...objects, ...device].sort((a, b) => a.at - b.at);
  ctx.log(`  ${jurors.length} from the backup jurors, ${objects.filter((r) => r.from === 'relay').length} from the relay, ${objects.filter((r) => r.from === 'bench').length} from their object, ${device.length} from the device`);
  if (!rows.length) {
    ctx.log('nothing: no backup juror served it, and nothing was said of it in that time');
    return;
  }
  for (const r of rows) ctx.log(`${stamp(r.at)}  ${r.from.padEnd(6)}  ${r.text}`);
}
