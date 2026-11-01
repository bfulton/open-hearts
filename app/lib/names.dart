// Whether a name may be shown to the other players: the service's own
// filter (service/functions/names.mjs, which says what it refuses and
// why), asked here before a name leaves the device, so that the profile
// says so at once rather than the service or the relay turning the name
// away. The same steps as names.mjs and name_fold.mjs, held to the same
// answers by service/functions/names.vectors.json.

import 'package:table/table.dart' show longestName;

import 'blocked_names.dart';

/// Digits and signs written for letters, read as those letters.
const _leet = {'0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', r'$': 's'};

final _leetChars = RegExp(r'[013457@$]');
final _signs = RegExp(r'[@$]');
final _marks = RegExp(r'[\p{M}\p{Cf}]', unicode: true);
final _notAWord = RegExp(r'[^\p{L}\p{N}@$]+', unicode: true);
final _aLetter = RegExp(r'\p{L}', unicode: true);
final _camel = RegExp(r'(\p{Ll})(\p{Lu})', unicode: true);

/// The characters cleanName (packages/table, names.dart) takes out of a
/// name that the filter would read as a break between words: control
/// characters, and the line and paragraph separators (names.mjs,
/// NOT_SENT).
final _notSent = RegExp(r'[\p{Cc}\u2028\u2029]', unicode: true);

/// [name] in lower case, accents and the like folded to plain letters
/// ([nameFolds]), without combining marks or invisible characters.
String _foldName(String name) {
  final out = StringBuffer();
  for (final rune in name.runes) {
    final ch = String.fromCharCode(rune);
    out.write(nameFolds[ch] ?? ch);
  }
  return out.toString().toLowerCase().replaceAll(_marks, '');
}

/// [name]'s words, folded; in a word with a letter in it, digits and
/// signs read as the letters they stand for.
List<String> _foldedWords(String name) => _foldName(name)
    .split(_notAWord)
    .map((w) => _aLetter.hasMatch(w) ? w.replaceAllMapped(_leetChars, (m) => _leet[m[0]]!) : w.replaceAll(_signs, ''))
    .where((w) => w.isNotEmpty)
    .toList();

/// Words that would make a name pass for Open Hearts or its staff, and
/// the game's own name as words (names.mjs, RESERVED_WORDS and
/// RESERVED_PHRASES): refused as the lists' are.
const _reservedWords = {
  'admin', 'administrator', 'administrador', 'administrateur', //
  'moderator', 'moderador', 'moderateur',
  'support', 'soporte', 'suporte', 'helpdesk',
  'staff', 'official', 'oficial', 'officiel', 'offiziell',
  'operator', 'operador', 'operateur', 'sysop',
  'openhearts',
};
const _reservedPhrases = [
  ['open', 'hearts'],
];

/// Cyrillic and Greek letters drawn like the Latin letters the reserved
/// words have, as those letters (names.mjs, LOOK_ALIKES): a name written
/// in them is held to the reserved words read this way, so that `Аdmin`
/// with a Cyrillic А does not pass for staff. Not to the lists, or a real
/// word in those alphabets could be taken for one of theirs.
const _lookAlikes = {
  'А': 'A', 'Е': 'E', 'К': 'K', 'М': 'M', 'Н': 'H', 'О': 'O', 'Р': 'P', 'С': 'C', 'Т': 'T', 'У': 'Y', 'Ѕ': 'S', 'І': 'I', 'Ү': 'Y', 'Һ': 'H', //
  'а': 'a', 'е': 'e', 'о': 'o', 'р': 'p', 'с': 'c', 'у': 'y', 'ѕ': 's', 'і': 'i', 'ԁ': 'd', 'һ': 'h', 'ү': 'y',
  'Α': 'A', 'Ε': 'E', 'Η': 'H', 'Ι': 'I', 'Κ': 'K', 'Μ': 'M', 'Ν': 'N', 'Ο': 'O', 'Ρ': 'P', 'Τ': 'T', 'Υ': 'Y',
  'α': 'a', 'ι': 'i', 'κ': 'k', 'ο': 'o', 'ρ': 'p', 'υ': 'u', 'η': 'n',
};

bool _blocked(String word) => blockedWords.contains(word) || _reservedWords.contains(word);

/// Whether [word] is refused by [listed]: on it, or on it once a
/// plural's s is taken off.
bool _refusedWord(String word, bool Function(String) listed) =>
    listed(word) || (word.length > 2 && word.endsWith('s') && listed(word.substring(0, word.length - 1)));

/// Whether [words], a name's in order, are refused; with [reservedOnly],
/// for passing for Open Hearts or its staff alone.
bool _refusedWords(List<String> words, {bool reservedOnly = false}) {
  bool refused(String word) => _refusedWord(word, reservedOnly ? _reservedWords.contains : _blocked);
  if (words.any(refused)) return true;
  // Letters one at a time, `f u c k`: each run of two or more read as a
  // word.
  var run = '';
  for (final w in [...words, '']) {
    if (w.runes.length == 1) {
      run += w;
      continue;
    }
    if (run.runes.length > 1 && refused(run)) return true;
    run = '';
  }
  for (final phrase in [if (!reservedOnly) ...blockedPhrases, ..._reservedPhrases]) {
    for (var i = 0; i + phrase.length <= words.length; i++) {
      var all = true;
      for (var j = 0; j < phrase.length && all; j++) {
        all = words[i + j] == phrase[j];
      }
      if (all) return true;
    }
  }
  if (reservedOnly) return false;
  final joined = words.join();
  return blockedAnywhere.any(joined.contains);
}

/// Whether [name] may not be shown to others. One no app sends is
/// refused outright: longer than [longestName], or with a character of
/// [_notSent] in it. Any other is held to the lists as written, and with
/// words run together as `ShitHead` parted; and for the reserved words,
/// with look-alike letters read as the Latin ones they are drawn like.
bool nameRefused(String name) {
  if (name.runes.length > longestName || _notSent.hasMatch(name)) return true;
  if (blockedSymbols.any(name.contains)) return true;
  final parted = name.replaceAllMapped(_camel, (m) => '${m[1]} ${m[2]}');
  if (_refusedWords(_foldedWords(name)) || _refusedWords(_foldedWords(parted))) return true;
  String latin(String s) => s.split('').map((ch) => _lookAlikes[ch] ?? ch).join();
  return _refusedWords(_foldedWords(latin(name)), reservedOnly: true) || _refusedWords(_foldedWords(latin(parted)), reservedOnly: true);
}
