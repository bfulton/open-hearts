// What has to hold before anything reaches production: what main is,
// and, for the site, the terms and the privacy policy as the ledger has
// them (terms.mjs). `oh deploy` asks first, to say what stands in the
// way; deploy.sh (for production), the relay's build step
// (service/bench/build.sh) and the store build (build_phone.sh) ask
// again themselves, so a release that skips oh is held to the same:
//
//   node ops/gate.mjs site     problems with releasing the site, or none
//   node ops/gate.mjs relay    the same for the relay worker
//   node ops/gate.mjs phone    the same for a store build of the app
//
// Exits 1, saying why, when anything is in the way.

import { pathToFileURL } from 'node:url';

import { context } from './env.mjs';
import { termsProblems } from './terms.mjs';

const TARGETS = ['site', 'relay', 'phone'];

/// The folders the site's deploy takes files from (site/build.mjs,
/// deploy.sh).
const PUBLISHED_FROM = ['site/pages', 'site/public', 'app/web', 'service/functions'];

/// Whether the site's deploy publishes [path], whether or not git
/// ignores it: each page in site/pages, each module in
/// service/functions but the tests and their fixtures, and every file
/// in site/public and app/web but those Wrangler leaves out of an
/// upload (a .DS_Store, and anything in a node_modules or .git folder).
function published(path) {
  const parts = path.split('/');
  const name = parts.at(-1);
  const folder = parts.slice(0, -1).join('/');
  if (folder === 'site/pages') return name.endsWith('.html');
  if (folder === 'service/functions') return name.endsWith('.mjs') && !/\.(test|fixtures)\.mjs$/.test(name);
  if (name === '.DS_Store' || parts.includes('node_modules') || parts.includes('.git')) return false;
  return path.startsWith('site/public/') || path.startsWith('app/web/');
}

const firstLine = (text) => text.trim().split('\n')[0] || 'git said nothing';

/// Production is built from what main is, and nothing else: no
/// uncommitted change, no file git does not track, and no commit that
/// main does not have, so that what runs is what was reviewed. Main as
/// it is now, too: if origin's main cannot be fetched, this clone's copy
/// of it may be older.
async function sourceProblems(ctx) {
  const problems = [];
  const fetched = await ctx.capture('git', ['fetch', '-q', 'origin', 'main']);
  if (fetched.code !== 0) problems.push(`origin/main could not be fetched: ${firstLine(fetched.out)}`);
  const head = (await ctx.capture('git', ['rev-parse', 'HEAD'])).out.trim();
  const main = await ctx.capture('git', ['rev-parse', 'origin/main']);
  if (main.code !== 0) problems.push(`origin/main could not be read: ${firstLine(main.out)}`);
  else if (head !== main.out.trim()) problems.push(`HEAD (${head.slice(0, 7)}) is not origin/main (${main.out.trim().slice(0, 7)}): production is built from main as it was reviewed`);
  const dirty = (await ctx.capture('git', ['status', '--porcelain'])).out.trim();
  if (dirty) problems.push(`uncommitted changes: ${dirty.split('\n').length} file(s)`);
  return problems;
}

/// Files git ignores that the site's deploy would publish. Listed with
/// -z, so that git writes each path as it is: without it, a path with a
/// space or a non-ASCII character comes back quoted, and would not match.
async function ignoredProblems(ctx) {
  const listed = (await ctx.capture('git', ['status', '--porcelain', '-z', '--ignored', '--untracked-files=all', '--', ...PUBLISHED_FROM])).out;
  const ignored = listed.split('\0').filter((l) => l.startsWith('!! ')).map((l) => l.slice(3)).filter(published);
  return ignored.length ? [`files git ignores would be published: ${ignored.join(', ')}`] : [];
}

/// What stands in the way of releasing [target] (site, relay or phone)
/// to production, in words; empty when nothing does.
export async function releaseProblems(ctx, target) {
  if (!TARGETS.includes(target)) throw new Error(`no release target ${target}`);
  const problems = await sourceProblems(ctx);
  if (target === 'site') problems.push(...(await ignoredProblems(ctx)), ...(await termsProblems(ctx)).problems);
  return problems;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const target = process.argv[2];
  const problems = await releaseProblems(context(), target);
  for (const p of problems) console.error(`gate: ${target}: ${p}`);
  process.exit(problems.length ? 1 : 0);
}
