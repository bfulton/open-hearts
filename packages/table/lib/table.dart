/// The table protocol: signed events, membership, departures and the
/// play chain, over an abstract transport and clock.
///
/// Pure Dart, like the engine. The app runs it over WebRTC in real
/// time; the simulator in `sim/` runs it over a scheduler in no time at
/// all, which is how the departure matrix in docs/06-service.md gets
/// run on every commit.
library;

export 'src/client.dart';
export 'src/clock.dart';
export 'src/events.dart';
export 'src/frame.dart';
export 'src/jury.dart';
export 'src/juror_duty.dart';
export 'src/matching.dart';
export 'src/model.dart';
export 'src/nip44.dart';
export 'src/nostr.dart';
export 'src/presence_relay.dart';
export 'src/pace.dart';
export 'src/rating.dart';
export 'src/record.dart';
export 'src/results.dart';
export 'src/schnorr_native.dart';
export 'src/sealed_pass.dart';
export 'src/relay_policy.dart';
export 'src/relay_transport.dart';
export 'src/relays.dart';
export 'src/signing.dart';
export 'src/spec.dart';
export 'src/time_bank.dart';
export 'src/timing.dart';
export 'src/transport.dart';
