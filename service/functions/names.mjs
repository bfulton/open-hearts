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
// or it has one of the few words refused even inside another. So is a
// name that would pass for Open Hearts itself or for the people who
// run it: the game's own name, and the words for its staff (RESERVED_
// WORDS, RESERVED_PHRASES), written in Latin letters or in Cyrillic and
// Greek ones drawn like them (LOOK_ALIKES). Words are compared folded
// (name_fold.mjs): accents and case aside, and `5h1t` read as `shit`. A
// word is matched whole, so Cassandra and Scunthorpe are names like any
// other, and so are Staffan and Supporter; what the lists miss, a report
// catches.
//
// A name no app sends is refused too: one longer than the app shows, or
// with a control character or a line break in it. The app cuts such a
// name, or takes those characters out, before it shows a name it is
// sent (packages/table, names.dart, cleanName), and what it then shows
// is not what was read here: `Ad\u0001min` is two words to the filter
// and `Admin` on the screen.

import { BLOCKED_ANYWHERE, BLOCKED_PHRASES, BLOCKED_SYMBOLS, BLOCKED_WORDS, NAME_FOLDS } from './blocked_names.mjs';
import { foldedWords, splitCamel } from './name_fold.mjs';

/// The longest name, in characters: what a profile keeps (profile.mjs),
/// and what the app cuts a name it is sent to (packages/table,
/// names.dart, longestName; profile.test.mjs holds the two equal).
export const NAME_MOST = 60;

/// The characters the app takes out of a name it is sent (packages/table,
/// names.dart, cleanName) that the filter would read as a break between
/// words: control characters, and the line and paragraph separators.
/// The others it takes out are format characters, which the filter
/// drops too (name_fold.mjs).
const NOT_SENT = /[\p{Cc}\u2028\u2029]/u;

/// Words that would make a name pass for Open Hearts or its staff, in
/// the app's five languages, folded: refused as the lists' words are.
const RESERVED_WORDS = [
  'admin', 'administrator', 'administrador', 'administrateur',
  'moderator', 'moderador', 'moderateur',
  'support', 'soporte', 'suporte', 'helpdesk',
  'staff', 'official', 'oficial', 'officiel', 'offiziell',
  'operator', 'operador', 'operateur', 'sysop',
  'openhearts',
];

/// The game's own name, as words: refused wherever a name holds it.
const RESERVED_PHRASES = [['open', 'hearts']];

/// Cyrillic and Greek letters drawn like the Latin letters the reserved
/// words have, as those letters (names.dart, lookAlikes): a name written
/// in them is held to the reserved words read this way, so that `Аdmin`
/// with a Cyrillic А does not pass for staff. Not to the lists, or a real
/// word in those alphabets could be taken for one of theirs.
const LOOK_ALIKES = {
  А: 'A', Е: 'E', К: 'K', М: 'M', Н: 'H', О: 'O', Р: 'P', С: 'C', Т: 'T', У: 'Y', Ѕ: 'S', І: 'I', Ү: 'Y', Һ: 'H',
  а: 'a', е: 'e', о: 'o', р: 'p', с: 'c', у: 'y', ѕ: 's', і: 'i', ԁ: 'd', һ: 'h', ү: 'y',
  Α: 'A', Ε: 'E', Η: 'H', Ι: 'I', Κ: 'K', Μ: 'M', Ν: 'N', Ο: 'O', Ρ: 'P', Τ: 'T', Υ: 'Y',
  α: 'a', ι: 'i', κ: 'k', ο: 'o', ρ: 'p', υ: 'u', η: 'n',
};

const blocked = new Set([...BLOCKED_WORDS, ...RESERVED_WORDS]);
const reserved = new Set(RESERVED_WORDS);

/// Whether [word] is refused by [listed]: on it, or on it once a
/// plural's s is taken off.
const refusedWord = (word, listed) => listed.has(word) || (word.length > 2 && word.endsWith('s') && listed.has(word.slice(0, -1)));

/// Whether [words], a name's in order, are refused; with [reservedOnly],
/// for passing for Open Hearts or its staff alone.
function refusedWords(words, reservedOnly = false) {
  const refused = (word) => refusedWord(word, reservedOnly ? reserved : blocked);
  if (words.some(refused)) return true;
  // Letters one at a time, `f u c k`: each run of two or more read as
  // a word.
  let run = '';
  for (const w of [...words, '']) {
    if ([...w].length === 1) {
      run += w;
      continue;
    }
    if ([...run].length > 1 && refused(run)) return true;
    run = '';
  }
  for (const phrase of [...(reservedOnly ? [] : BLOCKED_PHRASES), ...RESERVED_PHRASES]) {
    for (let i = 0; i + phrase.length <= words.length; i++) {
      if (phrase.every((p, j) => words[i + j] === p)) return true;
    }
  }
  if (reservedOnly) return false;
  const joined = words.join('');
  return BLOCKED_ANYWHERE.some((a) => joined.includes(a));
}

/// Whether [name] may not be shown to others. A name that is not a
/// string is not this filter's to judge (profile.mjs checks its shape).
/// One no app sends is refused outright: longer than [NAME_MOST], or
/// with a character of [NOT_SENT] in it.
export function nameRefused(name) {
  if (typeof name !== 'string') return false;
  if ([...name].length > NAME_MOST || NOT_SENT.test(name)) return true;
  if (BLOCKED_SYMBOLS.some((s) => name.includes(s))) return true;
  // As written, and with words run together as `ShitHead` parted; and
  // for the reserved words, with look-alike letters read as Latin ones.
  const parted = splitCamel(name);
  if (refusedWords(foldedWords(name, NAME_FOLDS)) || refusedWords(foldedWords(parted, NAME_FOLDS))) return true;
  const latin = (s) => [...s].map((ch) => LOOK_ALIKES[ch] ?? ch).join('');
  return refusedWords(foldedWords(latin(name), NAME_FOLDS), true) || refusedWords(foldedWords(latin(parted), NAME_FOLDS), true);
}
