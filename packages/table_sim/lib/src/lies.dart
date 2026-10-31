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
  /// Says it holds the two of clubs nowhere when it was dealt it: the
  /// hand cannot be led, so it is opened by its audits and given up, and
  /// the seat that lied is removed.
  declare,

  /// Seals its pass to nothing: three cards of the right shape that the
  /// seat it passed to could never open. It gets no further than its own
  /// turn — every seat checks the argument beside a seal, and a pass
  /// that fails it is not taken — and the clock has its seat there.
  seal,

  /// Keeps its piece of a departed person's secret to itself: the
  /// departed hand cannot be opened, and is given up.
  withhold;

  @override
  bool get releases => this != withhold;

  @override
  Map<String, Object?> declaration(Map<String, Object?> honest) =>
      this == declare ? {'seat': honest['seat'], 'position': -1} : honest;

  /// Sealed to nothing anybody holds: the shape of a pass, and three
  /// cards the receiver will never open.
  @override
  List<String> sealedPass(List<String> sealed, Random random) => this != seal
      ? sealed
      : [for (final _ in sealed) base64.encode([for (var b = 0; b < sealedBytes; b++) random.nextInt(256)])];
}
