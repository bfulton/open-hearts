/// Who is online, simulated: every registered key that is up, seen
/// by a heartbeat every five seconds; and the summons, delivered to a
/// juror's process if it is up.
library;

import '../jury.dart';
import '../signing.dart';
import '../spec.dart';
import 'sim_juror.dart';
import 'sim_network.dart';
import 'virtual_clock.dart';

class SimPresence implements Presence {
  SimPresence(this.net, this.clock);

  final SimNetwork net;
  final VirtualClock clock;
  final Map<PublicKey, SimJuror> _jurors = {};
  final Map<PublicKey, int> _lastUp = {};

  /// The jurors that come online only when a table calls for one —
  /// the bench of last resort a service would bring up. Several, not
  /// one: a table with bot seats needs [juryToHoldBots] before a
  /// juror can hold a seat at all, and the whole point of the call is
  /// that there is nobody else to make that up.
  final List<SimJuror> lastResorts = [];

  /// The first of them, for the tests that only care that somebody
  /// came.
  SimJuror? get lastResort => lastResorts.isEmpty ? null : lastResorts.first;

  /// How many times a table said it had nobody to draw from.
  int calls = 0;

  void register(SimJuror juror) {
    _jurors[juror.signer.publicKey] = juror;
  }

  void start() {
    _tick();
  }

  void _tick() {
    for (final j in _jurors.values) {
      if (!j.gone && net.isUp(j.signer.publicKey) && (!lastResorts.contains(j) || j.called)) _lastUp[j.signer.publicKey] = clock.nowMs;
    }
    clock.schedule(5000, _tick);
  }

  @override
  Set<PublicKey> online({required int withinMs}) =>
      {for (final e in _lastUp.entries) if (clock.nowMs - e.value < withinMs) e.key};

  @override
  void summon(PublicKey juror, Map<String, Object?> summons) {
    final j = _jurors[juror];
    if (j == null || j.gone || !net.isUp(juror)) return;
    final spec = TableSpec.parse(summons['table']);
    if (spec == null) return;
    clock.schedule(50, () => j.summoned(spec, summons['hand'] as int, [for (final k in summons['jurors'] as List) k as String]));
  }

  @override
  void callForJuror(String table) {
    calls++;
    // The whole bench, not one of it: a table short of jurors is
    // short by as many as the bot seats need, and answering one at a
    // time would take a call for each.
    for (final j in lastResorts) {
      if (j.called) continue;
      j.called = true;
      _lastUp[j.signer.publicKey] = clock.nowMs;
    }
  }
}
