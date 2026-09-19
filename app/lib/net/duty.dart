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

import 'mesh_transport.dart';
import 'relays.dart';

class Duty {
  Duty._(this.relays, this.presence, this.juror);

  final List<Uri> relays;
  final RelayPresence presence;
  final JurorDuty juror;

  static Duty? _current;

  /// The ICE servers a juror's own channels are made with, set once
  /// the app has fetched them (net/turn.dart). Read when a channel is
  /// made rather than when the duty starts, because the duty starts at
  /// the front door and the credentials arrive after; a channel made
  /// before them has STUN alone, which is most tables.
  static List<Map<String, Object?>> ice = const [];

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
    final juror = JurorDuty(
      relays: relays,
      signer: signer,
      presence: presence,
      log: logger,
      crypto: crypto,
      pinned: pinnedRelays(relays),
      // A juror here is a device like any other: it takes the table's
      // seats as peers and is dialled by them, so the play reaches it
      // on a data channel rather than through the relay
      // (docs/02-multiplayer.md). The relay under the mesh is what
      // signals the channels into being, and the lane for whatever has
      // no channel yet.
      dial: (spec, lane) => MeshTransport(
        relay: lane,
        peers: [for (final s in spec.seats) if (s is HumanSeat) s.key],
        iceServers: Duty.ice,
        log: logger == null ? null : (l) => logger('mesh: $l'),
      ),
    )..start();
    return _current = Duty._(relays, presence, juror);
  }

  static Duty? get current => _current;

  void close() {
    juror.close();
    presence.close();
    if (_current == this) _current = null;
  }
}
