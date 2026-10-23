// The operator's one command (docs/reference/oh.md), run as ./oh from
// the repository root:
//
//   ./oh help                  every command
//   ./oh help <command>        one, in full (or: ./oh <command> --help)
//   ./oh help --markdown       the reference, docs/reference/oh.md
//   ./oh <command> ...         run it
//
// Exits 0 when the command did what it was asked, 1 when it could not,
// and 2 when it was asked wrongly.

import { pathToFileURL } from 'node:url';

import { ARGUMENTS, COMMANDS, GROUPS } from './commands.mjs';
import { CREDENTIALS, Failed, Usage, context } from './env.mjs';

const usageOf = (c) =>
  ['oh', ...c.words, ...(c.args ?? []).map((a) => `<${a}>`), ...(c.flags ?? []).map((f) => (f.endsWith('=') ? `[--${f.slice(0, -1)} <${f.slice(0, -1)}>]` : `[--${f}]`)), ...(c.rest ? ['[-- <flutter build options>]'] : [])].join(' ');

/// The command [words] begin with, the longest that matches, and the
/// words after it.
export function commandOf(words) {
  let best = null;
  for (const c of COMMANDS) {
    if (c.words.length <= words.length && c.words.every((w, i) => w === words[i]) && (!best || c.words.length > best.words.length)) best = c;
  }
  return best;
}

/// [argv] after a command's own words, read as it says it is read:
/// {args, flags, rest}. Usage for anything it does not take.
export function parse(command, argv) {
  const args = {};
  const flags = {};
  const positional = [];
  let rest = [];
  const takes = new Set(command.flags ?? []);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--' && command.rest) {
      rest = argv.slice(i + 1);
      break;
    }
    if (a.startsWith('--')) {
      const name = a.slice(2);
      if (takes.has(name)) flags[name] = true;
      else if (takes.has(`${name}=`)) {
        const value = argv[++i];
        if (value === undefined || value.startsWith('--')) throw new Usage(`--${name} takes a value`);
        flags[name] = value;
      } else throw new Usage(`${command.words.join(' ')} takes no --${name}`);
    } else positional.push(a);
  }
  const names = command.args ?? [];
  if (positional.length < names.length) throw new Usage(`${command.words.join(' ')} needs ${names.slice(positional.length).map((n) => `<${n}>`).join(' ')}`);
  if (positional.length > names.length) throw new Usage(`${command.words.join(' ')} does not take ${positional.slice(names.length).join(' ')}`);
  names.forEach((n, i) => (args[n] = positional[i]));
  return { args, flags, rest };
}

/// One command's help, as the terminal shows it.
export function helpOf(c) {
  const lines = [usageOf(c), '', `  ${c.summary}`];
  if (c.more) lines.push(`  ${c.more}`);
  lines.push('');
  const rows = [
    ...(c.args ?? []).map((a) => [`<${a}>`, ARGUMENTS[a]]),
    ...(c.flags?.includes('apply') ? [['--apply', 'do it; without it, say what it would do and change nothing']] : []),
    ['needs', c.needs.join(', ') || 'nothing but this checkout'],
    ['how-to', c.howto],
    ['e.g.', c.example],
  ];
  const width = Math.max(...rows.map(([label]) => label.length));
  for (const [label, text] of rows) lines.push(`  ${label.padEnd(width)}  ${text}`);
  return lines.join('\n');
}

/// Every command, a line each, by group.
export function overview() {
  const lines = ['oh: the operator\'s one command (docs/reference/oh.md)', ''];
  for (const [group, title] of GROUPS) {
    lines.push(`${title}:`);
    for (const c of COMMANDS.filter((x) => x.group === group)) lines.push(`  ${['oh', ...c.words].join(' ').padEnd(22)} ${c.summary}`);
    lines.push('');
  }
  lines.push('oh help <command> says what one takes and needs. Nothing changes without --apply.');
  return lines.join('\n');
}

const anchor = (heading) => heading.toLowerCase().replace(/[^\w\- ]/g, '').trim().replace(/ /g, '-');

/// The reference, docs/reference/oh.md, every word of it from the table.
export function markdown() {
  const out = [
    '# The oh command',
    '',
    '<!-- Written by `./oh help --markdown` from ops/commands.mjs and ops/env.mjs. Change those, then run it again: ops/oh.test.mjs fails while this page and they differ. -->',
    '',
    '`./oh`, at the repository root, is how the operator does everything that runs Open Hearts: acting on an account, releasing, and setting up what the deployment is made of. It needs Node 22 or later, and nothing installed.',
    '',
    'Development tools, such as `./check.sh`, the chaos walk and the bot benchmarks, are not part of it: see [Tools](tools.md).',
    '',
    '## How every command behaves',
    '',
    '- **Nothing changes without `--apply`.** A command that changes anything says what it would do and stops; with `--apply` it does it.',
    '- **`./oh help <command>`**, or `--help` after it, says what the command takes, what it needs and where its how-to is.',
    '- **It prints no name, picture, code or email address.** Accounts, keys and rows only.',
    '- **Exit status:** 0 when it did what it was asked, 1 when it could not, 2 when it was asked wrongly.',
    '',
    '## Arguments',
    '',
    '| Argument | What it is |',
    '|---|---|',
    ...Object.entries(ARGUMENTS).map(([a, what]) => `| \`<${a}>\` | ${what} |`),
    '',
    '## Credentials',
    '',
    'Each command reads what it needs from the environment, and says which are missing.',
    '',
    '| Variable | What it is |',
    '|---|---|',
    ...Object.entries(CREDENTIALS).map(([name, what]) => `| \`${name}\` | ${what} |`),
    '',
  ];
  for (const [group, title, about] of GROUPS) {
    out.push(`## ${title}`, '', about, '');
    for (const c of COMMANDS.filter((x) => x.group === group)) {
      out.push(`### ${['oh', ...c.words].join(' ')}`, '', '```bash', usageOf(c), '```', '', [c.summary, c.more].filter(Boolean).join(' '), '');
      const [path, hash] = c.howto.split('#');
      out.push(`- **Needs:** ${c.needs.map((n) => (CREDENTIALS[n] ? `\`${n}\`` : n)).join(', ') || 'nothing but this checkout'}`);
      out.push(`- **How-to:** [${path.split('/').pop()}](../${path.replace(/^docs\//, '')}${hash ? `#${hash}` : ''})`);
      out.push(`- **Example:** \`${c.example}\``, '');
    }
  }
  return `${out.join('\n').trimEnd()}\n`;
}

/// [argv] run: what oh does, given what follows it.
export async function main(argv, ctx = context()) {
  try {
    if (!argv.length || argv[0] === 'help' || argv[0] === '--help' || argv[0] === '-h') {
      const asked = argv.slice(1);
      if (asked.includes('--markdown')) {
        process.stdout.write(markdown());
        return 0;
      }
      if (asked[0] === 'credentials') {
        for (const [name, what] of Object.entries(CREDENTIALS)) ctx.log(`${name}\n  ${what}`);
        return 0;
      }
      const c = asked.length ? commandOf(asked) : null;
      if (asked.length && !c) throw new Usage(`no command ${asked.join(' ')}`);
      ctx.log(c ? helpOf(c) : overview());
      return 0;
    }
    const words = argv.filter((a) => !a.startsWith('--'));
    const c = commandOf(words);
    if (!c) {
      const near = COMMANDS.filter((x) => x.words[0] === argv[0]).map((x) => ['oh', ...x.words].join(' '));
      throw new Usage(`no command ${argv.join(' ')}${near.length ? `; did you mean ${near.join(', ')}?` : '; oh help lists them'}`);
    }
    const after = argv.slice(argv.indexOf(c.words.at(-1)) + 1);
    if (after.includes('--help') && !(c.rest && after.indexOf('--') >= 0 && after.indexOf('--') < after.indexOf('--help'))) {
      ctx.log(helpOf(c));
      return 0;
    }
    await c.run(ctx, parse(c, after));
    return 0;
  } catch (e) {
    if (e instanceof Usage) {
      ctx.warn(e.message);
      return 2;
    }
    if (e instanceof Failed) {
      ctx.warn(e.message);
      return 1;
    }
    ctx.warn(e?.stack ?? String(e));
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
