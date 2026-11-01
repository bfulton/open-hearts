// A name as the filter reads it (names.mjs): its words, folded. The same
// steps as app/lib/names.dart, which the cases in names.vectors.json
// hold the two to, and as third_party/ldnoobw/build.mjs reads the
// lists with, so that an entry and a name are compared alike.

/// Digits and signs written for letters, read as those letters.
export const NAME_LEET = Object.freeze({ 0: 'o', 1: 'i', 3: 'e', 4: 'a', 5: 's', 7: 't', '@': 'a', $: 's' });

const LEET_CHARS = /[013457@$]/g;
const SIGNS = /[@$]/g;
const MARKS = /[\p{M}\p{Cf}]/gu;
const NOT_A_WORD = /[^\p{L}\p{N}@$]+/u;
const A_LETTER = /\p{L}/u;
const CAMEL = /(\p{Ll})(\p{Lu})/gu;

/// [name] in lower case, each character in [folds] (a table of
/// accented and other letters to plain ones) as it says, and without
/// combining marks or the invisible characters that join or part
/// letters (a zero-width space, a soft hyphen).
export function foldName(name, folds) {
  let out = '';
  for (const ch of name) out += folds[ch] ?? ch;
  return out.toLowerCase().replace(MARKS, '');
}

/// [name]'s words, folded: what is left between anything that is not a
/// letter, a digit, `@` or `$`. In a word with a letter in it, the
/// digits and signs of [NAME_LEET] are read as letters; a word of
/// digits alone is a number, and stays one.
export function foldedWords(name, folds) {
  return foldName(name, folds)
    .split(NOT_A_WORD)
    .map((w) => (A_LETTER.test(w) ? w.replace(LEET_CHARS, (c) => NAME_LEET[c]) : w.replace(SIGNS, '')))
    .filter((w) => w.length > 0);
}

/// [name] with a space where a small letter meets a capital, so that
/// words run together as `ShitHead` are read as two. The combining marks
/// and invisible characters [foldName] drops are dropped first, so that
/// one between the two letters does not keep them together:
/// `Shit\u200eHead` is shown as `ShitHead`.
export function splitCamel(name) {
  return name.replace(MARKS, '').replace(CAMEL, '$1 $2');
}
