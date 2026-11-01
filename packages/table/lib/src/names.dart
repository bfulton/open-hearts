/// Names as people give them: this device's own, and every name another
/// device sends (a room, a seating, a watched table, a kept game), made
/// fit to show before anything draws one.
library;

/// The longest name, in characters. The profile keeps names this long
/// (service/functions/profile.mjs; a test holds the two equal), and
/// [cleanName] cuts a received name to it by default.
const longestName = 60;

/// Control characters (C0, DEL and C1), the line and paragraph
/// separators U+2028 and U+2029, and the characters that change the
/// direction text is drawn in: the embeddings and overrides
/// U+202A–U+202E, the isolates U+2066–U+2069, and the marks U+200E,
/// U+200F and U+061C. A line break is not part of a name, and one left
/// in would split a sentence that shows the name ("Bob wins") across
/// lines. An override left open in a name reverses the text drawn after
/// it, so a name could make that sentence read as something else, or
/// show a word the name filter refuses spelled backwards. Other
/// invisible characters stay: the zero-width joiner is part of many
/// emoji.
final _notText = RegExp('[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]');

/// [name] without [_notText], trimmed, and no longer than [most]
/// characters.
String cleanName(String name, {int most = longestName}) {
  final chars = name.replaceAll(_notText, '').trim().runes.toList();
  return String.fromCharCodes(chars.length > most ? chars.sublist(0, most) : chars).trim();
}
