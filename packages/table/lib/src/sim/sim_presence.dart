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

  /// When each key was first heard from in its current run of being
  /// up — what [settled] measures.
  final Map<PublicKey, int> _firstUp = {};

  /// The jurors that come online only when a table calls for one —
  /// the backup jurors a service would bring up. Several, not
  /// one: a table with bot seats needs [juryToHoldBots] before a
  /// juror can hold a seat at all, and the table calls only when too
  /// few others are online to make that up.
  final List<SimJuror> lastResorts = [];

  /// The first of them, for the tests that only care that somebody
  /// came.
  SimJuror? get lastResort => lastResorts.isEmpty ? null : lastResorts.first;

  /// How many times a table said it had nobody to draw from.
  int calls = 0;

  void register(SimJuror juror) {
    _jurors[juror.signer.publicKey] = juror;
    if (juror.account case final account?) accounts[juror.signer.publicKey] = account;
  }

  /// The account each key belongs to, where it is not an account of
  /// its own: what a device's activation says in its presence
  /// (presence_relay.dart). The players' as well as the jurors', so a
  /// table can tell another device of a player's account.
  final Map<PublicKey, String> accounts = {};

  @override
  String accountOf(PublicKey key) => accounts[key] ?? key;

  void start() {
    _tick();
  }

  void _tick() {
    for (final j in _jurors.values) {
      final k = j.signer.publicKey;
      if (!j.canServe) {
        // Says it is going, and nothing more of itself, as a device's
        // presence does once it cannot serve (RelayPresence.canServe).
        _lastUp.remove(k);
        _firstUp.remove(k);
        continue;
      }
      if (!j.gone && net.isUp(k) && (!lastResorts.contains(j) || j.called)) {
        // A gap longer than the heartbeat starts the run again: a
        // juror that went and came back is newly here, not settled.
        if (clock.nowMs - (_lastUp[k] ?? -60000) > 15000) _firstUp[k] = clock.nowMs;
        _lastUp[k] = clock.nowMs;
      }
    }
    clock.schedule(5000, _tick);
  }

  @override
  Set<PublicKey> online({required int withinMs}) =>
      {for (final e in _lastUp.entries) if (clock.nowMs - e.value < withinMs) e.key};

  @override
  Set<PublicKey> settled({required int withinMs, required int forMs}) =>
      {for (final k in online(withinMs: withinMs)) if (clock.nowMs - (_firstUp[k] ?? clock.nowMs) >= forMs) k};

  /// How long a summons takes to arrive. A summons is not a table
  /// event: it goes to the juror's presence over a relay rather than
  /// down a data channel, so it is slower than the hand's own steps,
  /// and the gap decides what a juror has in hand before it has a
  /// deal to put it in (`test/deal_before_the_deal_test.dart`).
  int summonsMs = 50;

  /// Whether a summons carries the hand's draws. Without them a juror
  /// waits for the draws to be carried to it like any other event.
  bool withDraws = true;

  @override
  void summon(PublicKey juror, Map<String, Object?> summons) {
    final j = _jurors[juror];
    if (j == null || j.gone || !net.isUp(juror)) return;
    final spec = TableSpec.parse(summons['table']);
    if (spec == null) return;
    clock.schedule(
        summonsMs,
        () => j.summoned(spec, summons['hand'] as int, [for (final k in summons['jurors'] as List) k as String],
            juryId: summons['jury'] as String?,
            first: summons['first'] == true,
            draws: [
              if (withDraws)
                for (final d in summons['draws'] as List? ?? const []) Map<String, Object?>.from(d as Map),
            ]));
  }

  @override
  void callForJuror(String table) {
    calls++;
    // All the backup jurors, not one: a table short of jurors is
    // short by as many as the bot seats need, and answering one at a
    // time would take a call for each.
    for (final j in lastResorts) {
      if (j.called) continue;
      j.called = true;
      if (!j.canServe) continue;
      _firstUp[j.signer.publicKey] = clock.nowMs;
      _lastUp[j.signer.publicKey] = clock.nowMs;
    }
  }
}
