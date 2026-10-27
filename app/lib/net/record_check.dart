/// A kept game's check, as it goes: each hand as its check is done, and
/// then the verdict (review_page.dart).
///
/// On the web the check runs in a Web Worker of its own
/// (worker/review_worker.dart), so the page goes on drawing while a
/// game's deal is checked — every shuffle's proof and every card's
/// opening, tens of seconds of work on a phone. Elsewhere it runs here,
/// and the hands come together at the end.
library;

import 'dart:convert';

import 'package:deal/deal.dart';
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

/// A kept game as it came from the service: the table and what its
/// players were called, read here, and the record itself as it came,
/// which only the check reads — every event and every signature,
/// seconds of work on a phone, and off the page's thread on the web.
class KeptGame {
  const KeptGame({required this.spec, required this.text, this.names = const {}});

  /// A record this device holds already, as the service would hand it
  /// over.
  factory KeptGame.of(GameRecord record) => KeptGame(spec: record.spec, names: record.names, text: jsonEncode(record.toJson()));

  /// [text] as far as the page reads it: the table and the names, and
  /// none of the events. A game of either form: played at a refereed
  /// table, or kept before the referee. Null when it is not a record.
  static KeptGame? read(String text) {
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      if (GameRecord.versionOf(json) == GameRecord.version) {
        final head = GameRecord.parse({...json, 'log': const <Object?>[]});
        return head == null ? null : KeptGame(spec: head.spec, names: head.names, text: text);
      }
      final head = GameRecordV2.parse({...json, 'record': const <Object?>[], 'juries': const <Object?>[], 'releases': const <Object?>[]});
      return head == null ? null : KeptGame(spec: head.spec, names: head.names, text: text);
    } catch (_) {
      return null;
    }
  }

  final TableSpec spec;

  /// What each person was called at the table, by seat; not signed
  /// (GameRecord.names).
  final Map<int, String> names;

  /// The record, as it came.
  final String text;
}

/// How a kept game is checked: the platform's, and a test's to replace.
/// The whole of it, reading the record included.
Stream<RecordCheck> Function(KeptGame game) checkRecord = platform.checkRecord;

/// What a record whose events are not all signed by their authors fails
/// with.
const unsignedRecord = 'an event whose signature does not check';

/// A kept game's record as the check reads it: a game played at a
/// refereed table (`v3`), or one kept before the referee (`v2`); or why
/// there is nothing to check (`failed`).
typedef ReadRecord = ({GameRecord? v3, GameRecordV2? v2, RecordChecked? failed});

/// The check's reading of a kept game's record: every event, every
/// signature checked. A record kept before the referee whose events
/// read but are not all signed by their authors does not check out — it
/// is a record, and a false one — and what is not a record at all
/// cannot be checked. In a refereed table's log an event whose
/// signature does not check is an entry that changes nothing, as at the
/// table; the house signed for the log as it was, and a log changed
/// since is not that one ([verifyRecord]).
ReadRecord readRecord(String text) {
  const notARecord = (v3: null, v2: null, failed: RecordChecked(ok: false));
  final Object? json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    return notARecord;
  }
  if (GameRecord.versionOf(json) == GameRecord.version) {
    final record = GameRecord.parse(json);
    return record == null ? notARecord : (v3: record, v2: null, failed: null);
  }
  final record = GameRecordV2.parse(json);
  if (record != null) return (v3: null, v2: record, failed: null);
  if (GameRecordV2.parse(json, verifySignatures: false) != null) {
    return (v3: null, v2: null, failed: const RecordChecked(ok: false, reason: unsignedRecord));
  }
  return notARecord;
}

/// The check of a record [readRecord] read, with the deal's [crypto],
/// for this build's [house]: each hand told to [hand] as its check is
/// done, and then the verdict. A sealed game is not checked without the
/// deal.
RecordChecked checkRead(ReadRecord read, {required DealCrypto? crypto, PublicKey? house, void Function(TableReplayHand hand)? hand}) {
  final failed = read.failed;
  if (failed != null) return failed;
  final replay = TableReplay(onHand: hand);
  final v3 = read.v3;
  if (v3 != null) {
    final v = verifyRecord(v3, crypto: crypto, house: house, replay: replay);
    return RecordChecked(ok: v.ok, reason: v.ok ? null : v.reason, winners: v.winners);
  }
  final v2 = read.v2!;
  final v = verifyRecordV2(v2.spec, v2.record, juries: v2.juries, releases: v2.releases, crypto: crypto, allowPartial: true, replay: replay);
  return RecordChecked(ok: v.ok, reason: v.ok ? null : v.reason, winners: v.winners);
}
