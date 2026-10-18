// Whether a name may be shown to the other players: the filter the app
// stores ask of a game where people name themselves. The profile
// (profile.mjs) and a kept game's names (records.mjs) go by it here,
// the relay by it for what it passes on (service/do/relay.mjs), and the
// app by its twin, app/lib/names.dart, before a name leaves the device;
// names.vectors.json holds the two to the same answers.
//
// A name is refused when one of its words is a word on the lists in
// third_party/ldnoobw (blocked_names.mjs, made from them), its words
// hold a phrase on them, its letters spelt out one at a time make one,
// or it has one of the few words refused even inside another. Words
// are compared folded (name_fold.mjs): accents and case aside, and
// `5h1t` read as `shit`. A word is matched whole, so Cassandra and
// Scunthorpe are names like any other; what the lists miss, a report
// catches.

import { BLOCKED_ANYWHERE, BLOCKED_PHRASES, BLOCKED_SYMBOLS, BLOCKED_WORDS, NAME_FOLDS } from './blocked_names.mjs';
import { foldedWords, splitCamel } from './name_fold.mjs';

const blocked = new Set(BLOCKED_WORDS);

/// Whether [word] is refused: on the lists, or on them once a
/// plural's s is taken off.
const refusedWord = (word) => blocked.has(word) || (word.length > 2 && word.endsWith('s') && blocked.has(word.slice(0, -1)));

/// Whether [words], a name's in order, are refused.
function refusedWords(words) {
  if (words.some(refusedWord)) return true;
  // Letters one at a time, `f u c k`: each run of two or more read as
  // a word.
  let run = '';
  for (const w of [...words, '']) {
    if ([...w].length === 1) {
      run += w;
      continue;
    }
    if ([...run].length > 1 && refusedWord(run)) return true;
    run = '';
  }
  for (const phrase of BLOCKED_PHRASES) {
    for (let i = 0; i + phrase.length <= words.length; i++) {
      if (phrase.every((p, j) => words[i + j] === p)) return true;
    }
  }
  const joined = words.join('');
  return BLOCKED_ANYWHERE.some((a) => joined.includes(a));
}

/// Whether [name] may not be shown to others. A name that is not a
/// string is not this filter's to judge (profile.mjs checks its shape).
export function nameRefused(name) {
  if (typeof name !== 'string') return false;
  if (BLOCKED_SYMBOLS.some((s) => name.includes(s))) return true;
  // As written, and with words run together as `ShitHead` parted.
  return refusedWords(foldedWords(name, NAME_FOLDS)) || refusedWords(foldedWords(splitCamel(name), NAME_FOLDS));
}
