// Flows side by side: a suite's flows (flows.mjs, offline.mjs) shared out
// among a few workers, each with a rig of its own.
//
// A flow's devices are that flow's, and the rig under them is the
// worker's alone — its own relay on a port of its own, its own server,
// handlers and store, its own browser — so a flow beside another never
// meets it: not in the pool, not on presence, not as a juror. Within a
// worker the flows run one after another, as the whole suite used to.
//
//   --jobs N     workers (default 3; 1 is one after another, in order)
//   --serial     the same as --jobs 1
//
// A flow's lines are kept and printed together when it ends, under its
// verdict, so each reads as one story however the flows interleave.
// The slowest go first, by the last run's times
// (app/build/logs/<suite>-times.json), so the run is as short as its
// longest flow allows.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { argOf, log, logTo, root, startRelay, suite } from './drive.mjs';

/// How many workers this run asks for.
export function jobsAsked(fallback = 3) {
  if (process.argv.includes('--serial')) return 1;
  const asked = Number(argOf('jobs') ?? fallback);
  return Number.isInteger(asked) && asked > 0 ? asked : fallback;
}

/// Runs [flows] — `{ name, run }` — on [jobs] workers. [setUp](worker,
/// say) makes a worker's rig, where `say` is how a line from the rig
/// itself (a juror) reaches whichever flow the worker is running;
/// [runFlow](flow, rig) runs one flow on it and cleans up after it; and
/// [tearDown](rig) puts the rig away. Answers the number that failed.
export async function runFlows({ flows, jobs = jobsAsked(), only = argOf('only'), setUp, runFlow, tearDown }) {
  const chosen = flows.filter(({ name }) => !only || name.includes(only));
  const timesFile = join(root, 'app', 'build', 'logs', `${suite}-times.json`);
  let times = {};
  try {
    times = JSON.parse(readFileSync(timesFile, 'utf8'));
  } catch {}
  const workers = Math.max(1, Math.min(jobs, chosen.length));
  // One after another keeps the order the suite is written in.
  const queue = workers === 1 ? [...chosen] : [...chosen].sort((a, b) => (times[b.name] ?? 60) - (times[a.name] ?? 60));
  if (workers > 1) log(`${chosen.length} flows on ${workers} workers`);
  let failed = 0;
  const began = Date.now();
  await Promise.all(
    Array.from({ length: workers }, async (_, w) => {
      const tag = workers === 1 ? suite : `${suite}-${w + 1}`;
      const mark = workers === 1 ? '' : `[${w + 1}] `;
      // The flow this worker is running, for the rig's own lines.
      let current = null;
      const say = (...a) => (current ? current(...a) : log(mark, ...a));
      // The workers start a few seconds apart, so their browsers and
      // relays do not all start on the same second.
      await new Promise((r) => setTimeout(r, w * 4000));
      const rig = await setUp({ worker: w, tag, say });
      for (let flow; (flow = queue.shift()); ) {
        const lines = [];
        const sink = workers === 1 ? null : (line) => lines.push(line);
        current = sink ? (...a) => logTo.run(sink, () => log(...a)) : null;
        if (sink) log(`${mark}start ${flow.name}`);
        const start = Date.now();
        let verdict;
        try {
          await (sink ? logTo.run(sink, () => runFlow(flow, rig)) : runFlow(flow, rig));
          verdict = `ok    ${flow.name} (${((Date.now() - start) / 1000).toFixed(0)}s)`;
        } catch (e) {
          failed++;
          verdict = `FAIL  ${flow.name}: ${e.message}`;
        }
        current = null;
        times[flow.name] = Math.round((Date.now() - start) / 1000);
        if (sink) {
          const at = new Date().toISOString().slice(11, 19);
          console.log([`${at} ${mark}${verdict}`, ...lines.map((l) => `    ${l}`)].join('\n'));
        } else {
          log(verdict);
        }
      }
      await tearDown(rig);
    }),
  );
  try {
    mkdirSync(dirname(timesFile), { recursive: true });
    writeFileSync(timesFile, `${JSON.stringify(times, null, 1)}\n`);
  } catch {}
  log(`${chosen.length} flows in ${((Date.now() - began) / 1000).toFixed(0)}s`);
  return failed;
}

/// A flow's relay, on its worker's [port]: `relay()` starts it — once,
/// however often a flow asks — and `done()` stops it, and is waited on
/// as a flow ends. A flow whose app talks to a relay asks for one; a
/// flow that does not ask has none, so none passes on a relay another
/// flow left behind, and none meets another's devices or jurors on it.
/// Started outside the flow's own lines, as the rig's; its jurors speak
/// through [say].
export function flowRelay({ port, tag, say }) {
  let started = null;
  return {
    relay: () => (started ??= logTo.exit(() => startRelay({ port, tag, say }))),
    done: async () => {
      const was = started;
      started = null;
      await (await was?.catch(() => null))?.stop();
    },
  };
}
