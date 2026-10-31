/// The live table: a referee's log of signed events, the rules every side
/// applies to it, and the sides that play it — a person's device, and
/// the house's.
///
/// Pure Dart, like the engine. The app runs it over our relay in real
/// time; the simulator (packages/table_sim) runs it on a clock of its
/// own in no time at all.
library;

export 'src/bots.dart';
export 'src/client.dart';
export 'src/clock.dart';
export 'src/conduct.dart';
export 'src/events.dart';
export 'src/house.dart';
export 'src/journal.dart';
export 'src/legacy/v2_event.dart';
export 'src/legacy/v2_jury.dart';
export 'src/legacy/v2_record.dart';
export 'src/licence.dart';
export 'src/log.dart';
export 'src/matching.dart';
export 'src/nip44.dart';
export 'src/nostr.dart';
export 'src/pace.dart';
export 'src/presence_relay.dart';
export 'src/rating.dart';
export 'src/reactions.dart';
export 'src/record.dart';
export 'src/referee_line.dart';
export 'src/relay_line.dart';
export 'src/relay_policy.dart';
export 'src/relay_transport.dart';
export 'src/relays.dart';
export 'src/replay.dart';
export 'src/results.dart';
export 'src/rules.dart';
export 'src/schnorr_native.dart';
export 'src/sealed_pass.dart';
export 'src/signing.dart';
export 'src/spec.dart';
export 'src/time_bank.dart';
export 'src/timing.dart';
export 'src/watch.dart';
