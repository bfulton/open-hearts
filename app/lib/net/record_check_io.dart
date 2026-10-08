import 'package:table/table.dart';

import '../crypto/deal.dart';
import 'record_check.dart';

/// Here, on this thread, after a frame has had its chance to say the
/// check has begun.
Stream<RecordCheck> checkRecord(KeptGame game) async* {
  await Future<void>.delayed(Duration.zero);
  final (:record, :failed) = readRecord(game.text);
  if (record == null) {
    yield failed!;
    return;
  }
  final crypto = dealCrypto;
  if (record.spec.sealed && crypto == null) {
    yield const RecordChecked(ok: false);
    return;
  }
  final hands = <TableReplayHand>[];
  final v = verifyRecord(
    record.spec,
    record.record,
    juries: record.juries,
    releases: record.releases,
    crypto: crypto,
    allowPartial: true,
    replay: TableReplay(onHand: hands.add),
  );
  for (final h in hands) {
    yield HandChecked(h);
  }
  yield RecordChecked(ok: v.ok, reason: v.ok ? null : v.reason, winners: v.winners);
}
