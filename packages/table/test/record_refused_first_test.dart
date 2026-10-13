/// What a record is refused for before any of its decisions is read: a
/// sealed record without the deal's cryptography, a seat without a
/// licence for its key, and a decision that cannot be read at all. The
/// first two are the verdict whatever the decisions say, even a removal
/// of a seat the table does not have. The last is a decision that names
/// no seat at the table, which the replay reads ahead by index, or a
/// removal carried by something that cannot carry one: refused, where
/// the replay used to throw or take it.
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

  group('a decision that cannot be read', () {
    final spec = TableSpec(id: 'c' * 32, seed: 1, seats: seats);

    /// [kind] saying [body], by the first seat, as the record's one
    /// decision.
    String? refusal(EventKind kind, Map<String, Object?> body, {bool removal = true}) {
      final v = verifyRecord(spec, [
        Decision(
          turn: const TurnId(0, 0),
          event: TableEvent.sign(signers.first, table: spec.id, kind: kind, body: body),
          witnesses: {for (final s in signers) s.publicKey},
          among: {for (final s in signers) s.publicKey},
          removal: removal,
        ),
      ]);
      expect(v.ok, isFalse);
      return v.reason;
    }

    test('a removal of a seat the table does not have', () {
      for (final seat in [9, 4, -1]) {
        expect(refusal(EventKind.boot, {'hand': 0, 'turn': 0, 'seat': seat}), 'the boot at h0/pass names no seat at the table');
      }
    });

    test('an action by one', () {
      expect(refusal(EventKind.pass, {'hand': 0, 'turn': 0, 'seat': 9, 'cards': <String>[]}, removal: false),
          'the pass at h0/pass names no seat at the table');
    });

    test('an event about no seat at all', () {
      expect(refusal(EventKind.heartbeat, {'hand': 0, 'step': 0}), 'the heartbeat at h0/pass names no seat at the table');
      expect(refusal(EventKind.release, {'hand': 0, 'about': 0}, removal: false), 'the release at h0/pass names no seat at the table');
    });

    test('a removal carried by something that cannot carry one', () {
      expect(refusal(EventKind.play, {'hand': 0, 'turn': 0, 'seat': 0, 'card': '2C'}), 'the play at h0/pass is recorded as a removal');
      // One that names a seat it has no use for is no more a removal.
      expect(refusal(EventKind.heartbeat, {'hand': 0, 'step': 0, 'seat': 1}), 'the heartbeat at h0/pass is recorded as a removal');
    });
  });
}
