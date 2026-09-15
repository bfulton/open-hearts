/// What every open app does for the tables it is not at: says it is
/// online, and serves as a juror when drawn (docs/04-live-play.md).
///
/// One presence connection per relay for the life of the app, made the
/// first time a relay answers; a juror client per table summoned to, closed when
/// the table moves on. A player at a table is a juror elsewhere at the
/// same time — the draw is from whoever is online, at other tables or
/// in the lobby.
library;

import 'package:deal/deal.dart';
import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

import 'relays.dart';

class Duty {
  Duty._(this.relays, this.presence, this.juror);

  final List<Uri> relays;
  final RelayPresence presence;
  final JurorDuty juror;

  static Duty? _current;

  /// The duty on [relays], started if need be; a new list replaces it.
  /// With [crypto] the juror can serve sealed tables, holding a piece
  /// of every person's deal secret there.
  static Duty on(List<Uri> relays, Signer signer, {bool log = false, DealCrypto? crypto}) {
    final d = _current;
    if (d != null && listEquals(d.relays, relays)) return d;
    d?.close();
    void Function(String)? logger = log ? (l) => debugPrint('duty: $l') : null;
    // Presence prefers our own object, one per tag, and falls back to
    // the relays when it does not answer (net/relays.dart). Only
    // presence: a table's events go to the relays proper.
    final presence = RelayPresence(relays: presenceRelays(relays), signer: signer, log: logger);
    final juror = JurorDuty(relays: relays, signer: signer, presence: presence, log: logger, crypto: crypto, pinned: pinnedRelays(relays))..start();
    return _current = Duty._(relays, presence, juror);
  }

  static Duty? get current => _current;

  void close() {
    juror.close();
    presence.close();
    if (_current == this) _current = null;
  }
}
