/// This device online to everyone, from the moment a relay answers:
/// how the front door counts who is about, and how a device hears that
/// another device of its account has taken the account up
/// (net/in_use.dart; packages/table, presence_relay.dart).
///
/// One presence connection per relay for the life of the app. That is
/// all an open app does for anyone: a table is played on its own line
/// to its referee (live/lobby.dart), and no table this device is not at
/// asks anything of it (docs/explanation/live-play.md).
library;

import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

import 'in_use.dart';

class Online {
  Online._(this.relays, this.presence);

  final List<Uri> relays;
  final RelayPresence presence;

  static Online? _current;
  static Online? get current => _current;

  /// Online on [relays], if not already; a new list replaces the old.
  /// [log], if given, hears what presence does.
  static Online on(List<Uri> relays, Signer signer, {void Function(String)? log}) {
    final o = _current;
    if (o != null && listEquals(o.relays, relays)) return o;
    o?.close();
    final presence = RelayPresence(
      relays: relays,
      signer: signer,
      // Whose device this is, said with every beat: another device of
      // the account hears that it has been superseded (net/in_use.dart).
      activation: () => InUse.current.activation,
      log: log,
    );
    // Another device of the account heard taking it up: this one steps
    // back, and is online no longer.
    presence.superseded.listen((_) => InUse.current.stepBack());
    final online = _current = Online._(relays, presence);
    InUse.current.addListener(online._steppedBack);
    return online;
  }

  /// Another device of the account took it up, or the account is
  /// suspended: this one is online to nobody from now on.
  void _steppedBack() {
    if (InUse.current.shut) close();
  }

  /// Says this device is going, so that nobody counts it for a beat
  /// longer than it is here. Best effort by its nature: a backgrounded
  /// phone, a crash or a dead link says nothing at all.
  static void leaving() => _current?.presence.leaving();

  /// And back: the app returning to the foreground says it is here
  /// again, and the next beat clears the going everywhere.
  static void back() {
    final p = _current?.presence;
    if (p != null) p.silent = false;
  }

  void close() {
    InUse.current.removeListener(_steppedBack);
    presence.leaving();
    presence.close();
    if (_current == this) _current = null;
  }
}
