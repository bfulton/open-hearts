/// What a record is refused for before any of its decisions is read: a
/// sealed record without the deal's cryptography, and a seat without a
/// licence for its key. Each is the verdict whatever the decisions say,
/// even a removal of a seat the table does not have.
library;

import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  final signers = [for (var i = 0; i < 4; i++) SchnorrSigner.generate()];
  final seats = [for (final s in signers) HumanSeat(s.publicKey)];

  /// A removal of seat 9, at a table of four.
  List<Decision> noSuchSeat(String table) => [
        Decision(
          turn: const TurnId(0, 0),
          event: TableEvent.sign(signers.first, table: table, kind: EventKind.leave, body: {'hand': 0, 'turn': 0, 'seat': 9}),
          witnesses: const {},
          removal: true,
        ),
      ];

  test('a sealed record without the deal\'s cryptography', () {
    final spec = TableSpec(id: 'a' * 32, seed: 1, seats: seats, sealed: true);
    final v = verifyRecord(spec, noSuchSeat(spec.id));
    expect(v.ok, isFalse);
    expect(v.reason, 'a sealed record needs the deal\'s cryptography to check');
  });

  group('where licences are checked', () {
    setUp(() => licenceService = SchnorrSigner.generate().publicKey);
    tearDown(() => licenceService = '');

    test('a seat without a licence for its key', () {
      final spec = TableSpec(id: 'b' * 32, seed: 1, seats: seats);
      final v = verifyRecord(spec, noSuchSeat(spec.id));
      expect(v.ok, isFalse);
      expect(v.reason, 'seat 0 has no licence for its key');
    });
  });
}
