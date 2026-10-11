import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import { anchors, problems, slug } from './links.mjs';

test('a heading\'s anchor is GitHub\'s', () => {
  assert.equal(slug('What is guaranteed, and what is not'), 'what-is-guaranteed-and-what-is-not');
  assert.equal(slug('The `seated` stream'), 'the-seated-stream');
  assert.equal(slug('Relay — and TURN'), 'relay--and-turn');
  assert.equal(slug('See [doc 04](04.md) first'), 'see-doc-04-first');
  assert.equal(slug('Diátaxis'), 'diátaxis');
  assert.equal(slug('snake_case stays'), 'snake_case-stays');
});

test('anchors: each heading once, a repeat numbered, a fenced one not a heading', () => {
  const a = anchors(['# Top', '## Notes', '```', '# not a heading', '```', '## Notes', '<a id="kept"></a>'].join('\n'));
  assert.deepEqual([...a].sort(), ['kept', 'notes', 'notes-1', 'top']);
});

// A repository of its own, so that git says what is tracked.
function repo(files) {
  const root = mkdtempSync(join(tmpdir(), 'links-'));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(root, dirname(path)), { recursive: true });
    writeFileSync(join(root, path), text);
  }
  execFileSync('git', ['init', '-q'], { cwd: root });
  execFileSync('git', ['add', '-A'], { cwd: root });
  return root;
}

test('what resolves passes, and what does not is said with its line', () => {
  const root = repo({
    'README.md': [
      '# Readme',
      'See [the guide](docs/guide.md#install), [up](#readme) and [the site](https://example.com).',
      'Code is in `src/app.dart` and `src/lib/` and `src/*.dart` and `play/build-info.json`.',
      'Broken: [gone](docs/gone.md), [no heading](docs/guide.md#nowhere), `src/missing.dart`.',
      'An ignored output: `out/build/`. Inline `[not](a-link.md)` is code.',
      '```',
      'node src/app.dart src/old.mjs',
      '```',
    ].join('\n'),
    'docs/guide.md': '# Guide\n\n## Install\n\nBack to [the readme](../README.md).\n',
    'src/app.dart': '',
    'src/lib/x.dart': '',
  });
  const found = problems(root, ['README.md', 'docs/guide.md'], { ignored: (p) => p.startsWith('out/') });
  assert.deepEqual(found, [
    'README.md:4: docs/gone.md — no such file',
    'README.md:4: docs/guide.md#nowhere — no such heading in docs/guide.md',
    'README.md:4: `src/missing.dart` is not in the repository',
    'README.md:7: `src/old.mjs` is not in the repository',
  ]);
});

test('a path in a package\'s own README may be from the package', () => {
  const root = repo({ 'pkg/README.md': 'The rules are in `lib/rules.dart`, and `pkg/lib/rules.dart`.\n', 'pkg/lib/rules.dart': '' });
  // `lib/` is not a top-level entry, so only the second is checked, and it is there.
  assert.deepEqual(problems(root, ['pkg/README.md']), []);
});
