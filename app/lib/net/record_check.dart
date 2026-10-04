/// A kept game's check, as it goes: each hand as its check is done, and
/// then the verdict (review_page.dart).
///
/// On the web the check runs in a Web Worker of its own
/// (worker/review_worker.dart), so the page goes on drawing while a
/// game's deal is checked — every shuffle's proof and every card's
/// opening, tens of seconds of work on a phone. Elsewhere it runs here,
/// and the hands come together at the end.
library;

import 'package:table/table.dart';

import 'record_check_io.dart' if (dart.library.js_interop) 'record_check_web.dart' as platform;

sealed class RecordCheck {
  const RecordCheck();
}

/// A hand whose check is done; announced again if a later step adds to
/// it (the game's closing audit opens the last hand's cards).
class HandChecked extends RecordCheck {
  const HandChecked(this.hand);
  final TableReplayHand hand;
}

/// The verdict. [reason] says why a record failed; null with [ok] false
/// when it could not be checked here at all.
class RecordChecked extends RecordCheck {
  const RecordChecked({required this.ok, this.reason, this.winners = const []});
  final bool ok;
  final String? reason;
  final List<int> winners;
}

/// How a record is checked: the platform's, and a test's to replace.
Stream<RecordCheck> Function(GameRecord record) checkRecord = platform.checkRecord;
