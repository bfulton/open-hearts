// Whether a name may be shown to the other players: the service's own
// filter (service/functions/names.mjs, which says what it refuses and
// why), asked here before a name leaves the device, so that the profile
// says so at once rather than the service or the relay turning the name
// away. The same steps as names.mjs and name_fold.mjs, held to the same
// answers by service/functions/names.vectors.json.

import 'blocked_names.dart';

/// Digits and signs written for letters, read as those letters.
const _leet = {'0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', r'$': 's'};

final _leetChars = RegExp(r'[013457@$]');
final _signs = RegExp(r'[@$]');
final _marks = RegExp(r'[\p{M}\p{Cf}]', unicode: true);
final _notAWord = RegExp(r'[^\p{L}\p{N}@$]+', unicode: true);
final _aLetter = RegExp(r'\p{L}', unicode: true);
final _camel = RegExp(r'(\p{Ll})(\p{Lu})', unicode: true);

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

/// Whether [word] is refused: on the lists, or on them once a
/// plural's s is taken off.
bool _refusedWord(String word) =>
    blockedWords.contains(word) || (word.length > 2 && word.endsWith('s') && blockedWords.contains(word.substring(0, word.length - 1)));

/// Whether [words], a name's in order, are refused.
bool _refusedWords(List<String> words) {
  if (words.any(_refusedWord)) return true;
  // Letters one at a time, `f u c k`: each run of two or more read as a
  // word.
  var run = '';
  for (final w in [...words, '']) {
    if (w.runes.length == 1) {
      run += w;
      continue;
    }
    if (run.runes.length > 1 && _refusedWord(run)) return true;
    run = '';
  }
  for (final phrase in blockedPhrases) {
    for (var i = 0; i + phrase.length <= words.length; i++) {
      var all = true;
      for (var j = 0; j < phrase.length && all; j++) {
        all = words[i + j] == phrase[j];
      }
      if (all) return true;
    }
  }
  final joined = words.join();
  return blockedAnywhere.any(joined.contains);
}

/// Whether [name] may not be shown to others: as written, and with
/// words run together as `ShitHead` parted.
bool nameRefused(String name) {
  if (blockedSymbols.any(name.contains)) return true;
  final parted = name.replaceAllMapped(_camel, (m) => '${m[1]} ${m[2]}');
  return _refusedWords(_foldedWords(name)) || _refusedWords(_foldedWords(parted));
}
