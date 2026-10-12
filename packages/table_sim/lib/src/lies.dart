/// How a modified client lies (docs/explanation/fair-deal.md). A seat
/// saying it holds the two of clubs nowhere has nothing to prove, and
/// nothing can be made to prove it; a token sealed to one pair of eyes
/// is checked by an argument beside it. What the table does about each
/// is worth a test, and there is no testing it without committing it: a
/// client given a [Lie] as its [TableClient.conduct] does.
library;

import 'dart:convert';
import 'dart:math';

import 'package:deal/deal.dart';
import 'package:table/table.dart';

enum Lie implements SeatConduct {
  /// Says it holds the two of clubs nowhere and deals itself the hand
  /// all the same: it alone knows who leads, and it plays on while the
  /// rest of the table waits for a lead that is never coming. The loud
  /// version, and the table's clock has it at the audit it will not
  /// answer.
  declare,

  /// The same word, and then it waits with everybody else and answers
  /// the early audit like an honest seat. The patient version: nothing
  /// it does is out of step, and only the opened deal says which seat
  /// was dealt the card it disclaimed.
  hide,

  /// Seals its pass to nothing: three cards of the right shape that the
  /// seat it passed to could never open. It gets no further than its own
  /// turn — every seat checks the argument beside a seal, and a pass
  /// that fails it is not taken — and the clock has its seat there.
  seal;

  @override
  Map<String, Object?> declaration(Map<String, Object?> honest) =>
      this == seal ? honest : {'seat': honest['seat'], 'position': -1};

  @override
  int? leader(int? known) => this == hide ? null : known;

  /// Sealed to nothing anybody holds: the shape of a pass, and three
  /// cards the receiver will never open.
  @override
  List<String> sealedPass(List<String> sealed, Random random) => this != seal
      ? sealed
      : [for (final _ in sealed) base64.encode([for (var b = 0; b < sealedBytes; b++) random.nextInt(256)])];
}
