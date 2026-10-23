// What the name filter reads, made from the word lists beside this
// file (README.md): service/functions/blocked_names.mjs for the service
// and the relay, and app/lib/blocked_names.dart for the app.
//
//   node third_party/ldnoobw/build.mjs           writes both
//
// Both carry the same folding table and the same entries, so the app
// refuses a name exactly as the service and the relay do. The service's
// tests fail while either file is not what this would write.

import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { foldedWords } from '../../service/functions/name_fold.mjs';

const here = (file) => new URL(file, import.meta.url);
const root = (file) => new URL(`../../${file}`, import.meta.url);

/// The lists, by language, as the files have them.
export const LANGUAGES = Object.freeze(['en', 'es', 'pt', 'de', 'fr']);

/// Entries left out, by language, and why (README.md): each would
/// refuse real names, or words people put in a name for no harm.
export const LEFT_OUT = Object.freeze({
  en: {
    xx: 'refuses a name ending in XX',
    's&m': 'refuses the initials S M',
    butt: 'a common Pakistani and Kashmiri surname',
    dick: 'short for Richard',
    mong: 'a Chinese surname, and a name of the Hmong',
    poon: 'a Chinese surname',
    quim: 'a Catalan and Portuguese name, short for Joaquim',
    santorum: 'a surname',
    shota: 'a common Japanese name',
    'big black': 'everyday words',
    'girl on': 'everyday words',
    'hard core': 'everyday words',
    hardcore: 'an everyday word',
    'jelly donut': 'everyday words',
    'tainted love': 'a song',
    'tied up': 'everyday words',
  },
  es: {
    Pis: 'under four letters; a word in other languages',
    Trio: 'an everyday word',
    concha: 'a name, short for Concepción',
    infierno: 'an everyday word, hell',
    martillo: 'an everyday word, hammer, and a surname',
  },
  pt: {
    cu: 'under four letters; a word in other languages',
    pau: 'a Catalan name',
    amador: 'a Spanish and Portuguese name and surname',
    aranha: 'a Portuguese surname',
    ariano: 'an Italian and Spanish name',
    comer: 'an everyday word, to eat, and an Irish surname',
    inferno: 'an everyday word, hell',
    mama: 'what many call their mother',
    pinto: 'a Portuguese and Spanish surname',
    xana: 'a Galician and Asturian name',
  },
  de: {
    möse: 'folds to Mose, a name',
    mufti: 'a title, and a surname',
    rosette: 'a French name',
  },
  fr: {
    con: 'Spanish for "with"',
    cul: 'under four letters; a word in other languages',
    bitte: 'German for "please"',
    gerber: 'a German surname',
    péter: 'folds to Peter',
  },
});

/// Open Hearts' own, not the lists': words a name may not have even
/// inside another word, as in `fuckface`. Only those no real name or
/// everyday word has inside it — never `cunt` (Scunthorpe), `shit`
/// (Yamashita) or `cock` (Hancock).
export const ANYWHERE = Object.freeze(['faggot', 'fuck', 'nigger']);

/// The table name_fold.mjs's foldName reads: each character that is not its plain
/// letter in lower case — accented Latin letters, ligatures and the
/// full-width forms — as that plain letter, from Unicode's own
/// decompositions, and a few letters that have none.
export function nameFolds() {
  const folds = {};
  const ranges = [
    [0x00c0, 0x024f], // Latin-1 letters and Latin Extended-A and -B
    [0x1e00, 0x1eff], // Latin Extended Additional
    [0xfb00, 0xfb06], // Latin ligatures
    [0xff01, 0xff5e], // full-width ASCII
  ];
  for (const [from, to] of ranges) {
    for (let cp = from; cp <= to; cp++) {
      const ch = String.fromCodePoint(cp);
      const plain = ch.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase();
      if (plain && plain !== ch.toLowerCase()) folds[ch] = plain;
    }
  }
  // Letters Unicode does not decompose.
  for (const [ch, plain] of Object.entries({ ß: 'ss', ẞ: 'ss', æ: 'ae', Æ: 'ae', œ: 'oe', Œ: 'oe', ø: 'o', Ø: 'o', ł: 'l', Ł: 'l', đ: 'd', Đ: 'd', þ: 'th', Þ: 'th' })) {
    folds[ch] = plain;
  }
  return Object.fromEntries(Object.entries(folds).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

/// The entries, folded as a name is: {words, phrases, symbols,
/// anywhere} — single words, phrases of several words, entries with no
/// letter or digit in them (an emoji), and [ANYWHERE], each sorted and
/// once.
export function blockedOf(folds = nameFolds()) {
  const words = new Set();
  const phrases = new Map();
  const symbols = new Set();
  for (const lang of LANGUAGES) {
    const left = LEFT_OUT[lang] ?? {};
    for (const line of readFileSync(here(lang), 'utf8').split('\n')) {
      const entry = line.trim();
      if (!entry || Object.hasOwn(left, entry)) continue;
      const tokens = foldedWords(entry, folds);
      if (!tokens.length) symbols.add(entry);
      else if (tokens.length === 1) words.add(tokens[0]);
      else {
        phrases.set(tokens.join(' '), tokens);
        // And as one word, as it is often written.
        words.add(tokens.join(''));
      }
    }
  }
  const sorted = (xs) => [...xs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const anywhere = ANYWHERE.map((entry) => foldedWords(entry, folds).join(''));
  return { words: sorted(words), phrases: sorted(phrases.keys()).map((k) => phrases.get(k)), symbols: sorted(symbols), anywhere: sorted(anywhere) };
}

const HEADER = 'Made by third_party/ldnoobw/build.mjs from the word lists beside it\n// (CC BY 4.0; third_party/ldnoobw/README.md). Not edited by hand: run\n// node third_party/ldnoobw/build.mjs.';

/// service/functions/blocked_names.mjs, as it should be.
export function jsSource({ folds, words, phrases, symbols, anywhere }) {
  const list = (xs) => `[\n${xs.map((x) => `  ${JSON.stringify(x)},`).join('\n')}\n]`;
  return `// ${HEADER}

/// Each character that is not its plain letter in lower case, as that
/// plain letter (name_fold.mjs, foldName).
export const NAME_FOLDS = Object.freeze(${JSON.stringify(folds, null, 2)});

/// Words a name may not have.
export const BLOCKED_WORDS = Object.freeze(${list(words)});

/// Phrases a name may not have, word by word.
export const BLOCKED_PHRASES = Object.freeze(${list(phrases)});

/// Entries with no letter or digit, which a name may not have anywhere.
export const BLOCKED_SYMBOLS = Object.freeze(${list(symbols)});

/// Words a name may not have even inside another word.
export const BLOCKED_ANYWHERE = Object.freeze(${list(anywhere)});
`;
}

/// [s] as a single-quoted Dart string.
const dart = (s) => `'${s.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$')}'`;

/// app/lib/blocked_names.dart, as it should be.
export function dartSource({ folds, words, phrases, symbols, anywhere }) {
  return `// ${HEADER}

/// Each character that is not its plain letter in lower case, as that
/// plain letter (names.dart, foldName).
const nameFolds = <String, String>{
${Object.entries(folds)
  .map(([k, v]) => `  ${dart(k)}: ${dart(v)},`)
  .join('\n')}
};

/// Words a name may not have.
const blockedWords = <String>{
${words.map((w) => `  ${dart(w)},`).join('\n')}
};

/// Phrases a name may not have, word by word.
const blockedPhrases = <List<String>>[
${phrases.map((p) => `  [${p.map(dart).join(', ')}],`).join('\n')}
];

/// Entries with no letter or digit, which a name may not have anywhere.
const blockedSymbols = <String>[
${symbols.map((s) => `  ${dart(s)},`).join('\n')}
];

/// Words a name may not have even inside another word.
const blockedAnywhere = <String>[
${anywhere.map((s) => `  ${dart(s)},`).join('\n')}
];
`;
}

/// Both files, as they should be: {js, dart}.
export function sources() {
  const folds = nameFolds();
  const made = { folds, ...blockedOf(folds) };
  return { js: jsSource(made), dart: dartSource(made) };
}

export const JS_FILE = root('service/functions/blocked_names.mjs');
export const DART_FILE = root('app/lib/blocked_names.dart');

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { js, dart: dartText } = sources();
  writeFileSync(JS_FILE, js);
  writeFileSync(DART_FILE, dartText);
  const { words, phrases, symbols, anywhere } = blockedOf();
  console.log(`wrote ${JS_FILE.pathname} and ${DART_FILE.pathname}: ${words.length} words, ${phrases.length} phrases, ${symbols.length} symbols, ${anywhere.length} anywhere`);
}
