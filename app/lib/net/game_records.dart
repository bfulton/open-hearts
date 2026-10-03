/// Finished games, kept to be looked at afterwards (router.dart,
/// `/play/table/ID`; service/functions/records.mjs).
///
/// A player's device sends its record when the game is over; the first
/// copy is the one kept, so a table's other players sending theirs costs
/// nothing. Whoever opens a game fetches it by the table's id and checks
/// it themselves before showing a card of it (review_page.dart).
library;

import 'dart:convert';

import 'package:table/table.dart';

import 'household.dart' show askHandler;
import 'licence.dart' show handlerAt;
import 'turn_fetch_io.dart' if (dart.library.js_interop) 'turn_fetch_web.dart' as http;

/// Sends [record] to be kept, signed by [signer] for its table. True
/// once it is kept, by this device or by another of the table's.
Future<bool> keepGame(Signer signer, GameRecord record, {Uri? endpoint}) async {
  final table = record.spec.id;
  final answer = await askHandler('record', signer, {'table': table, 'record': jsonEncode(record.toJson())}, endpoint,
      what: table, timeout: const Duration(seconds: 30));
  return answer?.status == 200;
}

/// How a game is fetched: the platform's, and a test's to replace.
Future<String?> Function(Uri url) fetchText = http.getText;

/// The game kept for [table], read but not yet checked; null when none
/// is kept, or it cannot be reached, or what came back is not a record.
Future<GameRecord?> gameOf(String table, {Uri? base}) async {
  final at = base ?? handlerAt('record');
  if (at == null) return null;
  final text = await fetchText(at.replace(path: '${at.path}/$table'));
  if (text == null) return null;
  try {
    final record = GameRecord.parse(jsonDecode(text));
    return record?.spec.id == table ? record : null;
  } catch (_) {
    return null;
  }
}
