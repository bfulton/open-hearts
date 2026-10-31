/// A side's line to the table's referee: the table's object on our relay
/// (log.dart, docs/explanation/live-play.md).
///
/// The line is the whole of how a side hears the table and is heard by
/// it. It hands up the log in order and without gaps, from wherever the
/// side asks, however often the socket under it drops and is made again;
/// it says what the side sends until the log has it; and it asks the
/// referee for the time when a deadline is due. The app's runs over a
/// relay socket (relay_line.dart); the simulator's over its clock
/// (packages/table_sim).
library;

import 'events.dart';
import 'log.dart';

abstract class RefereeLine {
  /// Starts the line: the log from entry [from], in order, then every
  /// entry as the referee adds it, each once.
  void open(int from, void Function(LogEntry entry) onEntry);

  /// Sends [event] for the log. Said again on every new socket until
  /// an entry carrying it comes back.
  void send(TableEvent event);

  /// Asks the referee for a tick: an entry carrying nothing but its time,
  /// which is what lets every side see a deadline pass.
  void tick();

  /// Whether the line is up: its socket open and the log caught up.
  bool get up;

  /// Told whenever [up] changes.
  set onUp(void Function(bool up)? f);

  /// Why the referee turned this side away for good, if it did: another
  /// device of the account took it up, or the account was suspended.
  String? get refused;

  void close();
}
