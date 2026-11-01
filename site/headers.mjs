// Cloudflare Pages' `_headers` file (site/public/_headers), read the way
// Pages reads it, so that the browser rig serves the files it names with
// the headers production serves them with (e2e/drive.mjs, serveApp) and
// a test can say what a path is served with (headers.test.mjs).
//
// Only what the file uses is understood, and anything else is refused
// rather than guessed at: a rule with a placeholder, a host, or a
// header taken off ("! Name") would be served differently here than by
// Pages, and a test of it would say nothing.
//
//   - A line that starts at the left margin is a path, with `*` for any
//     run of characters, and the indented lines under it are the
//     headers it sets, `Name: value`.
//   - A path takes the headers of every rule that matches it, in the
//     order of the file; a header that more than one of them sets has
//     its values joined with ", " (Pages' documented behaviour). A
//     browser enforces each policy of a Content-Security-Policy that
//     is so joined, so the policies add up.

/// The rules of [text], as {pattern, set: [[name, value], …]}.
export function parseHeaders(text) {
  const rules = [];
  for (const [i, raw] of text.split('\n').entries()) {
    const at = `_headers line ${i + 1}`;
    if (raw.trim() === '' || raw.trim().startsWith('#')) continue;
    if (!/^\s/.test(raw)) {
      const pattern = raw.trim();
      if (!pattern.startsWith('/') || /[:\s]/.test(pattern)) throw new Error(`${at}: only a path, with * for any run, is understood here (not ${JSON.stringify(pattern)})`);
      rules.push({ pattern, set: [] });
      continue;
    }
    const line = raw.trim();
    if (line.startsWith('!')) throw new Error(`${at}: a header taken off is not understood here`);
    const colon = line.indexOf(':');
    if (colon <= 0 || !rules.length) throw new Error(`${at}: ${JSON.stringify(line)} is not "Name: value" under a path`);
    rules[rules.length - 1].set.push([line.slice(0, colon).trim(), line.slice(colon + 1).trim()]);
  }
  return rules;
}

const matcher = (pattern) => new RegExp(`^${pattern.split('*').map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`);

/// What [path] is served with under [rules]: header names, lower case,
/// to their values.
export function headersFor(rules, path) {
  const headers = {};
  for (const { pattern, set } of rules) {
    if (!matcher(pattern).test(path)) continue;
    for (const [name, value] of set) {
      const key = name.toLowerCase();
      headers[key] = key in headers ? `${headers[key]}, ${value}` : value;
    }
  }
  return headers;
}
