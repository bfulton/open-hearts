/// The clock a seat plays against (docs/explanation/live-play.md).
///
/// Not a clock per card. Every decision gets a grace that costs
/// nothing, and every hand a bank of thinking time that the part of a
/// decision past its grace drains. A seat can be booted once its bank
/// is empty and this decision's grace is spent, so a player who thinks
/// hard over three cards is never bothered, and one who takes fourteen
/// seconds over every card is bootable on their sixth. The bank refills
/// each hand. The deal's own turns and the audit are answered by a
/// present device in milliseconds and keep a fixed clock.
library;

import 'events.dart';

class TimeBank {
  const TimeBank({
    this.graceMs = 6000,
    this.passGraceMs = 20000,
    this.bankMs = 45000,
    this.fixedMs = 40000,
  });

  /// The standard table's clock. A table's own is in its timing
  /// (timing.dart), chosen by whoever started it.
  static const standard = TimeBank();

  /// What a card costs nothing up to.
  final int graceMs;

  /// What the pass costs nothing up to: thirteen cards to read first.
  final int passGraceMs;

  /// Thinking time per hand beyond the graces.
  final int bankMs;

  /// The deal's and the audit's turns: a device answers them by itself.
  /// Forty seconds, as the house has for the same steps of a bot seat
  /// (TableTiming.botDealsMs): on a slow machine a person's
  /// device takes as long over them.
  final int fixedMs;

  /// The grace for [turn], before the bank is touched.
  int graceOf(TurnId turn) => turn.isPass ? passGraceMs : graceMs;

  /// Whether [turn] plays against the bank at all.
  bool banks(TurnId turn) => turn.isPass || turn.isPlay;

  /// How long [turn] may stay open before Boot, with [bankLeftMs] of
  /// the seat's bank still unspent.
  int allowanceMs(TurnId turn, int bankLeftMs) => banks(turn) ? graceOf(turn) + bankLeftMs : fixedMs;
}
