// `oh photodna …` and the relay deploy's PhotoDNA module: Microsoft's
// module that makes a picture's PhotoDNA Edge Hashes, and the relay's
// code that calls it, kept out of this repository because Microsoft
// licenses them to Open Hearts as confidential (service/do/photodna_off.mjs).
// They are kept in a private bucket (infra/cloudflare.mjs), each file
// named by its SHA-256; config/openhearts.json pins the ones the relay
// is deployed with, and the deploy fetches exactly those into
// service/do/private/photodna/, which git ignores
// (docs/how-to/update-the-photodna-module.md).

import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { Failed, Usage, root } from './env.mjs';

/// Where the deploy puts the module, and what the relay's build is told
/// to use in the stand-in's place (service/do/wrangler.toml, `alias`).
export const MODULE_DIR = join(root, 'service/do/private/photodna');
export const MODULE_ALIAS = 'open-hearts-photodna:./private/photodna/edge.mjs';

/// The module's entry, which every module has.
export const ENTRY = 'edge.mjs';

/// Where each file is kept in the private bucket: by its SHA-256.
export const keyOf = (sha256) => `photodna/${sha256}`;

const sha256Of = (bytes) => createHash('sha256').update(bytes).digest('hex');

const configFile = (ctx) => ctx.configFile ?? join(root, 'config/openhearts.json');

/// The module's files as config/openhearts.json pins them, {name:
/// sha256}, or null for none.
export function pinsOf(config) {
  const module = config?.photodna?.module;
  if (module == null) return null;
  const names = Object.keys(module);
  if (!names.includes(ENTRY) || names.some((n) => !/^[A-Za-z0-9_.-]+$/.test(n) || !/^[0-9a-f]{64}$/.test(module[n]))) {
    throw new Failed('photodna.module in config/openhearts.json: name -> SHA-256 for each file, edge.mjs among them');
  }
  return module;
}

/// The module's files in [dir]: [{name, bytes, sha256}], every file in
/// it, edge.mjs among them.
async function filesIn(dir) {
  const names = (await readdir(dir, { withFileTypes: true })).filter((e) => e.isFile()).map((e) => e.name).sort();
  if (!names.includes(ENTRY)) throw new Failed(`${dir} has no ${ENTRY}`);
  return Promise.all(names.map(async (name) => {
    const bytes = await readFile(join(dir, name));
    return { name, bytes, sha256: sha256Of(bytes) };
  }));
}

/// [config]'s text with photodna.module made [pins], everything else in
/// it as it was written.
export function withPins(text, pins) {
  const at = text.indexOf('"photodna":');
  if (at < 0) throw new Failed('config/openhearts.json has no "photodna"');
  // The member runs to the brace that closes the one it opens.
  let i = text.indexOf('{', at);
  let depth = 0;
  for (; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) break;
  }
  const photodna = { ...JSON.parse(text.slice(text.indexOf('{', at), i + 1)), module: pins };
  const value = (k, v) =>
    k === 'module' ? ['{', Object.entries(v).map(([n, h]) => `      ${JSON.stringify(n)}: ${JSON.stringify(h)}`).join(',\n'), '    }'].join('\n') : JSON.stringify(v);
  const members = Object.entries(photodna).map(([k, v]) => `    ${JSON.stringify(k)}: ${value(k, v)}`);
  return `${text.slice(0, at)}"photodna": {\n${members.join(',\n')}\n  }${text.slice(i + 1)}`;
}

/// `oh photodna put <dir>`: every file in [dir] kept in the private
/// bucket, and config/openhearts.json made to pin them.
export async function put(ctx, { args, flags }) {
  if (!args.dir) throw new Usage('name the folder the module is in');
  const files = await filesIn(args.dir);
  const bucket = await ctx.privateFiles();
  const kept = new Set(await bucket.list('photodna/'));
  for (const f of files) {
    const there = kept.has(keyOf(f.sha256));
    if (!there && flags.apply) await bucket.write(keyOf(f.sha256), f.bytes, 'application/octet-stream');
    ctx.log(`${f.name}: ${f.sha256}${there ? ', kept already' : flags.apply ? ', kept' : ', to keep'}`);
  }
  const pins = Object.fromEntries(files.map((f) => [f.name, f.sha256]));
  const path = configFile(ctx);
  const text = await readFile(path, 'utf8');
  const next = withPins(text, pins);
  if (next === text) {
    ctx.log('config/openhearts.json pins these already');
    return;
  }
  if (!flags.apply) {
    ctx.log('nothing kept and config/openhearts.json unchanged; --apply keeps them and pins them');
    return;
  }
  await writeFile(path, next);
  ctx.log('config/openhearts.json now pins them: commit it, and the relay deploy from main uses them');
}

/// The pinned module's files from the private bucket, into [dir], each
/// checked against its pin. Resolves the pins, or null when nothing is
/// pinned and nothing is fetched.
export async function fetchModule(ctx, dir) {
  const pins = pinsOf(await ctx.config());
  if (!pins) return null;
  const bucket = await ctx.privateFiles();
  await mkdir(dir, { recursive: true });
  for (const [name, sha256] of Object.entries(pins)) {
    const bytes = await bucket.read(keyOf(sha256));
    if (!bytes) throw new Failed(`the PhotoDNA module's ${name} (${sha256}) is not in the private bucket: keep it there with oh photodna put`);
    if (sha256Of(bytes) !== sha256) throw new Failed(`the PhotoDNA module's ${name} in the private bucket is not what config/openhearts.json pins`);
    await writeFile(join(dir, name), bytes);
  }
  return pins;
}

/// `oh photodna get <dir>`: the pinned module, into [dir], to change it.
export async function get(ctx, { args }) {
  if (!args.dir) throw new Usage('name the folder to put the module in');
  const pins = await fetchModule(ctx, args.dir);
  if (!pins) throw new Failed('config/openhearts.json pins no PhotoDNA module (photodna.module)');
  for (const [name, sha256] of Object.entries(pins)) ctx.log(`${name}: ${sha256}`);
  ctx.log(`in ${args.dir}: keep it out of this repository`);
}
