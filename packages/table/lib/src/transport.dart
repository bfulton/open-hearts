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
  /// Sends [message] to every other peer at the table.
  void broadcast(Map<String, Object?> message);

  /// Everything that arrives, tagged with who it came from as the
  /// transport knows them — which the protocol never trusts over the
  /// signature inside.
  Stream<({PublicKey from, Map<String, Object?> message})> get incoming;

  /// Peers whose connection the transport has seen close.
  Stream<PublicKey> get disconnected;

  void close();
}
