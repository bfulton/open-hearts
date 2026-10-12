import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

import { anchors, codeProblems, problems, slug } from './links.mjs';

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
  // A number a heading already has is passed over, as GitHub does.
  assert.deepEqual([...anchors(['## Notes', '## Notes-1', '## Notes', '## Notes'].join('\n'))], ['notes', 'notes-1', 'notes-2', 'notes-3']);
  assert.deepEqual([...anchors(['## Notes-1', '## Notes', '## Notes'].join('\n'))], ['notes-1', 'notes', 'notes-2']);
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
      'See [the guide](pages/guide.md#install), [up](#readme) and [the site](https://example.com).',
      'Code is in `src/app.dart` and `src/lib/` and `src/*.dart` and `play/build-info.json`.',
      'Broken: [gone](pages/gone.md), [no heading](pages/guide.md#nowhere), `src/missing.dart`.',
      'An ignored output: `out/build/`. Inline `[not](a-link.md)` is code.',
      '```',
      'node src/app.dart src/old.mjs',
      '```',
    ].join('\n'),
    'pages/guide.md': '# Guide\n\n## Install\n\nBack to [the readme](../README.md).\n',
    'src/app.dart': '',
    'src/lib/x.dart': '',
  });
  const found = problems(root, ['README.md', 'pages/guide.md'], { ignored: (p) => p.startsWith('out/') });
  assert.deepEqual(found, [
    'README.md:4: pages/gone.md — no such file',
    'README.md:4: pages/guide.md#nowhere — no such heading in pages/guide.md',
    'README.md:4: `src/missing.dart` is not in the repository',
    'README.md:7: `src/old.mjs` is not in the repository',
  ]);
});

test('a path in a package\'s own README may be from the package', () => {
  const root = repo({ 'pkg/README.md': 'The rules are in `lib/rules.dart`, and `pkg/lib/rules.dart`.\n', 'pkg/lib/rules.dart': '' });
  // `lib/` is not a top-level entry, so only the second is checked, and it is there.
  assert.deepEqual(problems(root, ['pkg/README.md']), []);
});

test('code that cites the docs: the file, an anchor, and a section named in quotes', () => {
  const root = repo({
    'docs/guide.md': '# Guide\n\n## Where the app is\n\n## Appeals and juries\n',
    'src/a.dart': [
      '// (docs/guide.md, "Where the app is") and docs/guide.md#where-the-app-is',
      '// (docs/guide.md, "Appeals and',
      '// juries"), a quote that runs on',
      '// docs/gone.md, docs/guide.md#nowhere, (docs/guide.md, "Nowhere")',
      '// (docs/guide.md, "Neither',
    ].join('\n'),
    'src/b.bin': Buffer.from([0, 1, 2, ...Buffer.from('docs/gone.md')]),
  });
  assert.deepEqual(codeProblems(root, ['src/a.dart', 'src/b.bin']), [
    'src/a.dart:4: docs/gone.md — no such file',
    'src/a.dart:4: docs/guide.md#nowhere — no such heading',
    'src/a.dart:4: docs/guide.md, "Nowhere" — no such heading',
    'src/a.dart:5: docs/guide.md, "Neither… — no such heading',
  ]);
});
