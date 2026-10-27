import 'package:table/table.dart';

import '../crypto/deal.dart';
import 'licence.dart' show houseKey;
import 'record_check.dart';

/// Here, on this thread, after a frame has had its chance to say the
/// check has begun.
Stream<RecordCheck> checkRecord(KeptGame game) async* {
  await Future<void>.delayed(Duration.zero);
  final hands = <TableReplayHand>[];
  final verdict = checkRead(readRecord(game.text), crypto: dealCrypto, house: houseKey.isEmpty ? null : houseKey, hand: hands.add);
  for (final h in hands) {
    yield HandChecked(h);
  }
  yield verdict;
}
