/// What every open app does for the tables it is not at: says it is
/// online, and serves as a juror when drawn (docs/04-live-play.md) —
/// while it can deal. Every live table is sealed, so a device whose
/// deal did not load, or whose worker has failed for good since, could
/// serve none of them: it says nothing of itself, and still hears the
/// others (presence_relay.dart, `canServe`).
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

import 'in_use.dart';
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
  /// of every person's deal secret there. [log], if given, hears what
  /// the duty does, its mesh's channels among it.
  static Duty on(List<Uri> relays, Signer signer, {void Function(String)? log, DealCrypto? crypto, DealWorker? dealWorker}) {
    final d = _current;
    if (d != null && listEquals(d.relays, relays)) return d;
    d?.close();
    // Presence has a connection of its own; a table's events go on the
    // table's.
    final presence = RelayPresence(
      relays: relays,
      signer: signer,
      canServe: () => crypto != null && dealWorker != null && !dealWorker.dead,
      // Whose device this is, said with every beat: no table draws it
      // as a juror where its account sits, and another device of the
      // account hears that it has been superseded (net/in_use.dart).
      activation: () => InUse.current.activation,
      log: log,
    );
    // Another device of the account heard taking it up: this one steps
    // back, and the duty with it.
    presence.superseded.listen((_) => InUse.current.stepBack());
    final juror = JurorDuty(
      relays: relays,
      signer: signer,
      presence: presence,
      log: log,
      crypto: crypto,
      dealWorker: dealWorker,
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
        log: log == null ? null : (l) => log('mesh: $l'),
      ),
    )..start();
    final duty = _current = Duty._(relays, presence, juror);
    InUse.current.addListener(duty._steppedBack);
    return duty;
  }

  /// Another device of the account took it up: this one is no juror and
  /// online to nobody from now on (net/in_use.dart).
  void _steppedBack() {
    if (InUse.current.elsewhere) close();
  }

  static Duty? get current => _current;

  /// Says whether this device is at a table, which presence carries so
  /// that another table's draw can prefer it: somebody mid-game has a
  /// reason to still be here in a minute where somebody in the lobby
  /// has none (docs/04-live-play.md).
  static set seated(bool v) {
    final p = _current?.presence;
    if (p != null) p.status = v ? RelayPresence.seated : 'online';
  }

  /// Says this device is going, so that nobody waits out a missed
  /// heartbeat to find out. Best effort by its nature: a backgrounded
  /// phone, a crash or a dead link says nothing at all, which is why
  /// the table still times out whoever is silent.
  static void leaving() => _current?.presence.leaving();

  /// And back: the app returning to the foreground says it is here
  /// again, and the next beat clears the going everywhere.
  static void back() {
    final p = _current?.presence;
    if (p != null) p.silent = false;
  }

  void close() {
    InUse.current.removeListener(_steppedBack);
    // One last word before the sockets go, so that no table waits out
    // a heartbeat to learn this device is not a juror any more.
    presence.leaving();
    juror.close();
    presence.close();
    if (_current == this) _current = null;
  }
}
