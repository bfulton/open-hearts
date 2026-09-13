/// How events reach the other seats.
///
/// A [Transport] carries opaque JSON maps between peers identified by
/// public key and reports when a peer's connection is known to be gone
/// — WebRTC sees that within a few seconds. Everything else about
/// absence is the protocol's own business (heartbeats and timeouts in
/// the client). The app implements this over WebRTC data channels; the
/// simulator implements it over a scheduler with latency, loss and
/// partitions.
library;

import 'signing.dart';

abstract class Transport {
  /// Sends [message] to every other peer at the table. [everywhere],
  /// by every path the transport has — over relays, to every relay
  /// rather than the one it writes to — for what has gone unanswered
  /// or must reach a juror: the peer that cannot read the relay this
  /// device writes to is exactly the one that has to hear it.
  void broadcast(Map<String, Object?> message, {bool everywhere = false});

  /// The paths this transport reads right now — over relays, the
  /// relays it is connected to — for a heartbeat to carry, so that a
  /// writer can pick a path its readers can read. Empty when the
  /// question does not arise.
  List<String> get paths;

  /// What [peer] says it reads, from its latest heartbeat: a relay
  /// transport writes each event to the first relay in its order that
  /// every peer heard from lately reads, and to all of them when
  /// there is no such relay.
  void heard(PublicKey peer, List<String> paths);

  /// Everything that arrives, tagged with who it came from as the
  /// transport knows them — which the protocol never trusts over the
  /// signature inside.
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming;

  /// Peers whose connection the transport has seen close.
  Stream<PublicKey> get disconnected;

  void close();
}
