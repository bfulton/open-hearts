// `oh table`: one timeline of what each side said of a table, from
// Workers Logs and New Relic, asked through a fetch that stands in for
// both (ops/table.mjs).

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Usage } from './env.mjs';
import { table } from './table.mjs';

const id = '83167bb6681da6f1b6f4ab8931028fbb';
const at = (s) => Date.parse(`2026-10-23T23:${s}Z`);

/// A context whose fetch answers Workers Logs from [lines], by dataset
/// and filter as Workers Logs does, and New Relic from [reports]; what
/// was asked is kept. A line of text is matched by what its message
/// holds; a line of JSON has no message, and is matched by its fields.
function context({ lines = {}, reports = [], env = {} } = {}) {
  const said = [];
  const asked = [];
  return {
    said,
    asked,
    env: { CLOUDFLARE_API_TOKEN: 't', CLOUDFLARE_ACCOUNT_ID: 'a', ...env },
    now: () => at('59:00.000'),
    log: (line) => said.push(line),
    warn: (line) => said.push(`oh: ${line}`),
    fetch: async (url, init) => {
      const body = JSON.parse(init.body);
      if (url.includes('newrelic')) {
        asked.push({ nrql: body.variables.q });
        return Response.json({ data: { actor: { account: { nrql: { results: reports } } } } });
      }
      const dataset = body.parameters.datasets[0];
      const [filter] = body.parameters.filters;
      asked.push({ dataset, filter: `${filter.key} ${filter.operation} ${filter.value}`, from: body.timeframe.from, to: body.timeframe.to });
      const matches = (e) =>
        filter.key === '$metadata.message'
          ? filter.operation === 'includes' && (e.$metadata?.message ?? '').includes(filter.value)
          : filter.operation === 'eq' && e.source?.[filter.key] === filter.value;
      const events = (lines[dataset] ?? []).filter((e) => e.timestamp >= body.timeframe.from && e.timestamp < body.timeframe.to && matches(e));
      return Response.json({ success: true, result: { events: { events: events.slice(0, body.limit) } } });
    },
  };
}

const juror = (time, message) => ({ timestamp: at(time), source: { message }, $metadata: { message } });
// Workers Logs keeps a line of JSON as its fields, with no message.
const json = (time, source) => ({ timestamp: at(time), source, $metadata: {} });

test('the jurors, the relay, their object and the device, in the order things happened', async () => {
  const ctx = context({
    lines: {
      containers: [juror('29:02.724', `summoned to ${id} for hand 0 by adbbad`), juror('31:21.000', '83167bb6 stalled: connected no')],
      'cloudflare-workers': [
        json('29:03.100', { relay: 'open', tag: 'table:83167bb6', as: 'unanswered', sockets: 5 }),
        json('29:02.000', { bench: 'woken', table: 'table:83167bb6', status: 200, waitedMs: 1200 }),
        json('30:44.000', { relay: 'close', tag: 'table:83167bb6', as: 'device', code: 1006, clean: false, openS: 100, sockets: 4 }),
        // Another table's, which is not this one's business.
        json('30:45.000', { relay: 'close', tag: 'table:5cad2c8f', as: 'device', code: 1006, clean: false, openS: 9, sockets: 0 }),
        json('30:46.000', { bench: 'stop', table: 'table:5cad2c8f' }),
      ],
    },
    reports: [{ timestamp: at('31:05.000'), errorMessage: 'live: game lost: juror quorum lost', seen: 'juror quorum lost at h0/t49', line: '1 of 1 open', build: 'abc' }],
    env: { NEW_RELIC_API_KEY: 'k', NEW_RELIC_ACCOUNT_ID: '1' },
  });
  await table(ctx, { args: { table: id }, flags: {} });
  const timeline = ctx.said.filter((l) => l.startsWith('2026'));
  assert.deepEqual(timeline, [
    '2026-10-23 23:29:02.000  bench   woken, status 200, waitedMs 1200',
    `2026-10-23 23:29:02.724  jurors  summoned to ${id} for hand 0 by adbbad`,
    '2026-10-23 23:29:03.100  relay   socket open as unanswered; 5 on the tag',
    '2026-10-23 23:30:44.000  relay   socket close as device code 1006 unclean, open 100 s; 4 on the tag',
    '2026-10-23 23:31:05.000  device  live: game lost: juror quorum lost: juror quorum lost at h0/t49; 1 of 1 open (build abc)',
    '2026-10-23 23:31:21.000  jurors  83167bb6 stalled: connected no',
  ]);
  assert.ok(ctx.said.includes('  2 from the backup jurors, 2 from the relay, 1 from their object, 1 from the device'));
  // Asked for the table by the first eight of its id, as each side names it.
  assert.deepEqual(
    ctx.asked.filter((a) => a.dataset).map((a) => [a.dataset, a.filter]),
    [
      ['containers', '$metadata.message includes 83167bb6'],
      ['cloudflare-workers', 'tag eq table:83167bb6'],
      ['cloudflare-workers', 'table eq table:83167bb6'],
    ],
  );
  assert.match(ctx.asked.find((a) => a.nrql).nrql, /WHERE `table` = '83167bb6' SINCE 3 days ago/);
});

test('without New Relic the device is left out, and said so; its first eight are enough', async () => {
  const ctx = context({ lines: { containers: [juror('29:02.724', 'x')] } });
  await table(ctx, { args: { table: '83167bb6' }, flags: { days: '1' } });
  assert.ok(ctx.said.some((l) => l.includes('the device: not asked')));
  assert.ok(!ctx.asked.some((a) => a.nrql));
  assert.equal(ctx.asked[0].to - ctx.asked[0].from, 24 * 60 * 60 * 1000, 'the one day asked for');
});

test('a window that fills a page is asked again in halves, so nothing is cut off', async () => {
  // More lines than one answer holds (2000), over the last two days.
  const now = at('59:00.000');
  const many = Array.from({ length: 2500 }, (_, i) => {
    const t = now - 2 * 24 * 60 * 60 * 1000 + i * 60 * 1000;
    return { timestamp: t, source: { message: `line ${i}` }, $metadata: { message: `83167bb6 line ${i}` } };
  });
  const ctx = context({ lines: { containers: many } });
  await table(ctx, { args: { table: id }, flags: {} });
  const shown = ctx.said.filter((l) => l.includes('  jurors  83167bb6 line '));
  assert.equal(shown.length, 2500, 'every line, once');
  assert.ok(ctx.asked.filter((a) => a.dataset === 'containers').length > 1, 'asked in more than one window');
  assert.ok(!ctx.said.some((l) => l.startsWith('oh: ')), 'and nothing said to be missing');
});

test('nothing said of it, said so; and a table named wrongly is not looked for', async () => {
  const ctx = context();
  await table(ctx, { args: { table: id }, flags: {} });
  assert.ok(ctx.said.some((l) => l.startsWith('nothing:')));
  for (const bad of ['83167bb', 'table:83167bb6', id.toUpperCase(), `${id}00`]) {
    await assert.rejects(table(context(), { args: { table: bad }, flags: {} }), Usage, bad);
  }
  await assert.rejects(table(context(), { args: { table: id }, flags: { days: '0' } }), Usage);
});
