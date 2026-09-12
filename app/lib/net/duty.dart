/// What every open app does for the tables it is not at: says it is
/// online, and serves as a juror when drawn (docs/04-live-play.md).
///
/// One presence socket for the life of the app, made the first time a
/// relay answers; a juror client per table summoned to, closed when
/// the table moves on. A player at a table is a juror elsewhere at the
/// same time — the draw is from whoever is online, at other tables or
/// in the lobby.
library;

import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

class Duty {
  Duty._(this.url, this.presence, this.juror);

  final Uri url;
  final RelayPresence presence;
  final JurorDuty juror;

  static Duty? _current;

  /// The duty on [url], started if need be; a new relay replaces it.
  static Duty on(Uri url, Signer signer, {bool log = false}) {
    final d = _current;
    if (d != null && d.url == url) return d;
    d?.close();
    void Function(String)? logger = log ? (l) => debugPrint('duty: $l') : null;
    final presence = RelayPresence(url: url, signer: signer, log: logger);
    final juror = JurorDuty(url: url, signer: signer, presence: presence, log: logger)..start();
    return _current = Duty._(url, presence, juror);
  }

  static Duty? get current => _current;

  void close() {
    juror.close();
    presence.close();
    if (_current == this) _current = null;
  }
}
