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

/// How long a device may hear nothing at all, with something it sent
/// waiting on an answer, before its transport takes itself for cut off
/// ([Transport.cutOff]). Our relay answers everything it is sent, and a
/// table's heartbeats go out every five seconds, so ten seconds of
/// nothing is the line down — found inside the fifteen a juror is given
/// to play a bot seat's move, and well inside the half minute a juror is
/// given before a table stops counting it.
const unansweredMs = 10000;

/// How long an answer may take on a slow line: something sent waits
/// this long before its going unanswered counts at all, so that a
/// relay quiet only because there was nothing to say — every peer on a
/// channel of its own — is not a line down the moment a word goes out.
const answerMs = 3000;

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

  /// Whether this device is cut off itself: it has heard nothing at all
  /// for [unansweredMs] while something it sent waits on an answer, or
  /// has no way out.
  /// What it does not hear then is its own line down, not the table
  /// gone — a juror heard from by everyone else is not one to give up
  /// on — and the client waits for its line rather than ending the
  /// game for want of a jury it cannot hear (client.dart,
  /// _judgeQuorum).
  bool get cutOff;

  /// Who is at the table to be reached directly, as the protocol comes
  /// to know them: the seats at the start, and the hand's jurors as
  /// each jury carries and is redrawn.
  ///
  /// A transport that dials peers — the app's mesh — opens a channel
  /// to each and drops the ones that leave; one that writes to a relay
  /// has nothing to do with it and ignores it. This is how a juror
  /// stops being the party with no path of its own
  /// (docs/explanation/live-play.md): it is summoned over the relay and then
  /// spoken to directly, like anybody else at the table.
  void reach(Set<PublicKey> peers) {}

  void close();
}
