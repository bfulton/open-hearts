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

  /// A juror that comes online only when a table calls for one — the
  /// juror of last resort a service would bring up.
  SimJuror? lastResort;

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
      if (!j.gone && net.isUp(j.signer.publicKey) && (j != lastResort || j.called)) _lastUp[j.signer.publicKey] = clock.nowMs;
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
    final j = lastResort;
    if (j != null && !j.called) {
      j.called = true;
      _lastUp[j.signer.publicKey] = clock.nowMs;
    }
  }
}
