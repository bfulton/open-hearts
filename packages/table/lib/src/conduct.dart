/// What a seat says where it could say something else.
///
/// The library's conduct is the honest one, and the only one anything a
/// person runs has. The simulator's seats lie (packages/table_sim): what
/// the table does about a seat that says it holds the two of clubs
/// nowhere, or seals its pass to nothing, is worth a test, and there is
/// no testing it without a seat that does it
/// (docs/explanation/fair-deal.md).
library;

import 'dart:math';

class SeatConduct {
  const SeatConduct();

  /// This seat's word on the lead card at the deal's last round, given
  /// [honest], the word its deal gives.
  Map<String, Object?> declaration(Map<String, Object?> honest) => honest;

  /// The cards of this seat's pass as it sends them, given [sealed],
  /// each sealed to the seat it passes to; [random] for anything made
  /// up in their place.
  List<String> sealedPass(List<String> sealed, Random random) => sealed;

  /// A pass this seat says before its own, given [honest], or null for
  /// none. Whatever a table makes of it, it is signed and in the log.
  Map<String, Object?>? passBefore(Map<String, Object?> honest) => null;

  /// Whether this seat says its piece of a departed person's secret.
  bool get releases => true;
}
