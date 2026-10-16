// What has to hold before anything reaches production. `oh deploy` asks
// first, to say what stands in the way; deploy.sh (for production) and
// the relay's build step (service/bench/build.sh) ask again themselves,
// so a deploy that skips oh is held to the same:
//
//   node ops/gate.mjs site     problems with releasing the site, or none
//   node ops/gate.mjs relay    the same for the relay worker
//
// Exits 1, saying why, when anything is in the way.

import { pathToFileURL } from 'node:url';

import { context } from './env.mjs';

/// Production is built from what main is, and nothing else: no
/// uncommitted change and no commit that main does not have, so that
/// what runs is what was reviewed.
async function sourceProblems(ctx) {
  const problems = [];
  await ctx.capture('git', ['fetch', '-q', 'origin', 'main']);
  const head = (await ctx.capture('git', ['rev-parse', 'HEAD'])).out.trim();
  const main = (await ctx.capture('git', ['rev-parse', 'origin/main'])).out.trim();
  if (!main) problems.push('origin/main could not be read');
  else if (head !== main) problems.push(`HEAD (${head.slice(0, 7)}) is not origin/main (${main.slice(0, 7)}): production is built from main as it was reviewed`);
  const dirty = (await ctx.capture('git', ['status', '--porcelain', '--untracked-files=no'])).out.trim();
  if (dirty) problems.push(`uncommitted changes: ${dirty.split('\n').length} file(s)`);
  return problems;
}

/// What stands in the way of releasing [target] (site or relay) to
/// production, in words; empty when nothing does.
export async function releaseProblems(ctx, target) {
  if (target !== 'site' && target !== 'relay') throw new Error(`no release target ${target}`);
  return sourceProblems(ctx);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const target = process.argv[2];
  const problems = await releaseProblems(context(), target);
  for (const p of problems) console.error(`gate: ${target}: ${p}`);
  process.exit(problems.length ? 1 : 0);
}
