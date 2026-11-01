/// Names as people give them: this device's own, and every name another
/// device sends (a room, a seating, a watched table, a kept game), made
/// fit to show before anything draws one.
library;

/// The longest name, in characters: what the profile keeps
/// (service/functions/profile.mjs, a test holding them equal), and the
/// most of a name another device sends that is kept.
const longestName = 60;

/// Control characters (C0, DEL and C1), and the characters that change
/// the direction text is drawn in: the embeddings and overrides
/// U+202A–U+202E, the isolates U+2066–U+2069, and the marks U+200E,
/// U+200F and U+061C. An override left open in a name reverses the text
/// drawn after it, so a name could make the sentence around it ("Bob
/// wins") read as something else, or show a word the name filter
/// refuses spelled backwards. Other invisible characters stay: the
/// zero-width joiner is part of many emoji.
final _notText = RegExp('[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]');

/// [name] without [_notText], trimmed, and no longer than [most]
/// characters.
String cleanName(String name, {int most = longestName}) {
  final chars = name.replaceAll(_notText, '').trim().runes.toList();
  return String.fromCharCodes(chars.length > most ? chars.sublist(0, most) : chars).trim();
}
