// Checks the repository's Markdown for references that have gone stale:
// every relative link resolves, every anchor names a heading, and every
// repository path named in code exists.
//
//     node docs/links.mjs
//
// A path in code (`service/do/relay.mjs`, or a word in a fenced block)
// is checked when it starts with one of the repository's top-level
// entries and git does not ignore it, so a deployed path
// (`play/build-info.json`) or a build output (`crypto/deal/target/`) is
// not taken for a stale one. A path with a wildcard or a placeholder
// (`*.test.mjs`, `<tag>`) names many files, so is not checked. Links to
// other sites are not fetched: where they point is not this
// repository's to keep.
//
// Code cites the docs too (`docs/explanation/service.md, "Where the app
// is"`), so every tracked file is read for a docs/….md path: the file
// is there, an anchor after it names a heading, and a section named in
// quotes after it is a heading (one whose quote runs onto the next line,
// a heading that starts so).
//
// The vendored crates (crypto/vendor/<crate>/), ZXing (app/web/zxing/)
// and New Relic's agent (app/web/observability.js) are their authors',
// so are not checked.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const notOurs = (f) =>
  /^crypto\/vendor\/[^/]+\//.test(f) || f.startsWith('app/web/zxing/') || f === 'app/web/observability.js';

/// A heading's anchor as GitHub makes it: lower case, punctuation gone,
/// spaces to hyphens; the second of a name gets -1, the third -2.
export function slug(text) {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[`*_~]/g, (c) => (c === '_' ? '_' : ''))
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s/g, '-');
}

/// Each line of [text] outside fenced blocks, with its number, and the
/// words inside them.
function scan(text) {
  const prose = [];
  const fenced = [];
  let fence = null;
  text.split('\n').forEach((line, i) => {
    const open = line.match(/^\s*(`{3,}|~{3,})/);
    if (fence) {
      if (open && open[1][0] === fence[0] && open[1].length >= fence.length) fence = null;
      else fenced.push([i + 1, line]);
    } else if (open) {
      fence = open[1];
    } else {
      prose.push([i + 1, line]);
    }
  });
  return { prose, fenced };
}

/// The anchors a Markdown file has: its headings', and any <a id> or
/// <a name> in it. A repeated heading is numbered as GitHub numbers it
/// (github-slugger): past every slug already given, its own included,
/// so `Notes`, `Notes-1`, `Notes` are notes, notes-1 and notes-2.
export function anchors(text) {
  const out = new Set();
  const seen = new Map();
  for (const [, line] of scan(text).prose) {
    const h = line.match(/^#{1,6}\s+(.*?)\s*#*\s*$/);
    if (h) {
      const base = slug(h[1]);
      let given = base;
      while (seen.has(given)) {
        seen.set(base, seen.get(base) + 1);
        given = `${base}-${seen.get(base)}`;
      }
      seen.set(given, 0);
      out.add(given);
    }
    for (const a of line.matchAll(/<a\s+(?:id|name)="([^"]+)"/g)) out.add(a[1]);
  }
  return out;
}

const pathLike = /^[\w.@-]+(?:\/[\w.@-]+)*\/?$/;

/// What is wrong in [files] (paths relative to [root]): one line each,
/// `file:line: why`.
export function problems(root, files, { ignored = () => false } = {}) {
  const top = new Set(execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).split('\n').map((f) => f.split('/')[0]));
  const out = [];
  const anchorsOf = new Map();
  const anchorsIn = (file) => {
    if (!anchorsOf.has(file)) anchorsOf.set(file, anchors(readFileSync(join(root, file), 'utf8')));
    return anchorsOf.get(file);
  };
  // A path named in code: it exists from the root or from the file, or
  // it is not one this repository keeps.
  const named = (file, n, word) => {
    const w = word.replace(/[.,:;)]+$/, '');
    if (!pathLike.test(w) || !w.includes('/') || /[*<>{}$]/.test(w)) return;
    if (!top.has(w.split('/')[0])) return;
    if (existsSync(join(root, w)) || existsSync(join(root, dirname(file), w))) return;
    if (ignored(w)) return;
    out.push(`${file}:${n}: \`${w}\` is not in the repository`);
  };
  for (const file of files) {
    const text = readFileSync(join(root, file), 'utf8');
    const { prose, fenced } = scan(text);
    for (const [n, line] of prose) {
      const bare = line.replace(/`[^`]*`/g, (code) => ' '.repeat(code.length));
      for (const m of bare.matchAll(/!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) {
        const target = m[1];
        if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue;
        const [path, anchor] = target.split('#');
        const into = path ? relative(root, resolve(root, dirname(file), decodeURI(path))) : file;
        if (path && !existsSync(join(root, into))) {
          out.push(`${file}:${n}: ${target} — no such file`);
          continue;
        }
        if (anchor !== undefined && into.endsWith('.md') && !anchorsIn(into).has(decodeURIComponent(anchor))) {
          out.push(`${file}:${n}: ${target} — no such heading in ${into}`);
        }
      }
      for (const code of line.matchAll(/`([^`]+)`/g)) named(file, n, code[1].trim());
    }
    for (const [n, line] of fenced) {
      for (const word of line.split(/\s+/)) named(file, n, word);
    }
  }
  return out;
}

/// What is wrong in what [files] (code, relative to [root]) say of the
/// docs: one line each, `file:line: why`.
export function codeProblems(root, files) {
  const out = [];
  const anchorsOf = new Map();
  const anchorsIn = (file) => {
    if (!anchorsOf.has(file)) anchorsOf.set(file, anchors(readFileSync(join(root, file), 'utf8')));
    return anchorsOf.get(file);
  };
  for (const file of files) {
    const bytes = readFileSync(join(root, file));
    if (bytes.subarray(0, 8000).includes(0)) continue;
    bytes
      .toString('utf8')
      .split('\n')
      .forEach((line, i) => {
        for (const m of line.matchAll(/\bdocs\/[\w./-]*?\w\.md(?:#([\w-]+))?(?:[,:;]?\s*["“]([^"”]*)(["”])?)?/g)) {
          const doc = m[0].match(/^docs\/[\w./-]*?\.md/)[0];
          const where = `${file}:${i + 1}`;
          if (!existsSync(join(root, doc))) {
            out.push(`${where}: ${doc} — no such file`);
            continue;
          }
          const [, anchor, title, closed] = m;
          if (anchor && !anchorsIn(doc).has(anchor)) out.push(`${where}: ${doc}#${anchor} — no such heading`);
          if (title !== undefined && title.trim()) {
            const s = slug(title);
            const found = closed ? anchorsIn(doc).has(s) : [...anchorsIn(doc)].some((a) => a.startsWith(s));
            if (!found) out.push(`${where}: ${doc}, "${title.trim()}${closed ? '"' : '…'} — no such heading`);
          }
        }
      });
  }
  return out;
}

/// Whether git ignores [path] in [root]: a build output or a secret.
/// Asked as a directory too, since a rule for one (`/Frameworks/`)
/// cannot match a path that is not there to be seen as one.
function gitIgnores(root) {
  const asked = (p) => {
    try {
      execFileSync('git', ['check-ignore', '-q', '--no-index', p], { cwd: root });
      return true;
    } catch {
      return false;
    }
  };
  return (path) => asked(path) || (!path.endsWith('/') && asked(`${path}/`));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = fileURLToPath(new URL('..', import.meta.url));
  const tracked = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' })
    .split('\n')
    .filter((f) => f && !notOurs(f) && existsSync(join(root, f)));
  const docs = tracked.filter((f) => f.endsWith('.md'));
  // Not this check's own test, whose paths are made up to be wrong.
  const code = tracked.filter((f) => !f.endsWith('.md') && f !== 'docs/links.test.mjs');
  const found = [...problems(root, docs, { ignored: gitIgnores(root) }), ...codeProblems(root, code)];
  for (const p of found) console.log(p);
  console.log(
    found.length
      ? `${found.length} stale reference(s)`
      : `${docs.length} docs and ${code.length} other files: every reference resolves`,
  );
  process.exitCode = found.length ? 1 : 0;
}
