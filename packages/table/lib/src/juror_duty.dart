/// Serving as a juror: the client any player's app runs in the
/// background, and the one the service runs as juror of last resort.
///
/// A summons names a table and a hand. The duty opens a client on that
/// table's tag — following, not seated — tells it which hand and which
/// jury it was drawn into, and closes it once the table has moved past
/// every hand it served. Several tables at once are several clients.
library;

import 'dart:async';

import 'package:deal/deal.dart';

import 'client.dart';
import 'clock.dart';
import 'presence_relay.dart';
import 'relay_transport.dart';
import 'signing.dart';

class JurorDuty {
  JurorDuty(
      {required this.relays,
      required this.signer,
      required this.presence,
      this.log,
      Clock? clock,
      this.silenceAfterMs = 120000,
      this.pinned = 0,
      this.crypto})
      : clock = clock ?? WallClock();

  /// The relays a summoned client follows a table on; every one of
  /// them, whichever the table's peers write to (relays.dart).
  final List<Uri> relays;
  final Signer signer;
  final RelayPresence presence;
  final void Function(String line)? log;
  final Clock clock;

  /// The silence a juror's clients count as absence; the protocol's
  /// two minutes, shorter in a test.
  final int silenceAfterMs;

  /// The deal's primitives, to serve at sealed tables.
  final DealCrypto? crypto;

  /// Relays at the front of [relays] kept primary — ours to run.
  final int pinned;

  final Map<String, ({TableClient client, RelayTransport transport})> _tables = {};
  StreamSubscription<Summons>? _sub;
  Timer? _sweep;

  /// Tables this client is following as a juror.
  int get serving => _tables.length;

  /// The clients following, by table id, for a test to look at.
  Map<String, TableClient> get clients => {for (final e in _tables.entries) e.key: e.value.client};

  /// Verdicts given, over every table.
  int verdicts = 0;

  void start() {
    _sub = presence.summonses.listen(_onSummons);
    _sweep = Timer.periodic(const Duration(seconds: 10), (_) => _sweepTables());
  }

  void _onSummons(Summons s) {
    var t = _tables[s.spec.id];
    if (t == null) {
      final transport = RelayTransport(relays: relays, signer: signer, table: s.spec.id, log: log, pinned: pinned);
      if (s.spec.sealed && crypto == null) {
        log?.call('duty: summoned to a sealed table without the deal\'s cryptography; cannot serve');
        return;
      }
      final client =
          TableClient(spec: s.spec, signer: signer, transport: transport, clock: clock, silenceAfterMs: silenceAfterMs, crypto: crypto);
      client.log = log;
      t = _tables[s.spec.id] = (client: client, transport: transport);
      client.changes.listen((_) {
        verdicts = _tables.values.fold(0, (n, t) => n + t.client.record.where((d) => d.verdict?.author == signer.publicKey).length);
      });
      client.start();
      log?.call('summoned to ${s.spec.id} for hand ${s.hand} by ${s.from.substring(0, 6)}');
    }
    t.client.serveFor(s.hand, s.jurors);
  }

  void _sweepTables() {
    for (final e in List.of(_tables.entries)) {
      final c = e.value.client;
      // A line every ten seconds per table followed: where the juror
      // stands, for a log read after the fact.
      log?.call('following ${e.key}: hand ${c.game.handNumber} ${c.game.phase.name} step ${c.step} pause ${c.pause?.name} '
          'heartbeats ${c.heartbeatsSent} deferred ${c.deferred} serving ${c.serving}');
      if (c.serving) continue;
      log?.call('done with ${e.key}');
      c.close();
      e.value.transport.close();
      _tables.remove(e.key);
    }
  }

  void close() {
    _sub?.cancel();
    _sweep?.cancel();
    for (final t in _tables.values) {
      t.client.close();
      t.transport.close();
    }
    _tables.clear();
  }
}

/// A bench of them. A table whose bot seats are the jury's to hold
/// needs [juryToHoldBots] jurors before it can hold any (jury.dart),
/// and the call for a last resort comes exactly when there is nobody
/// else to make that number up — so what answers is a bench rather
/// than a juror, and a quiet night keeps the bots' hands hidden
/// instead of handing them back to the table.
///
/// Each seat on the bench is its own identity, its own presence and
/// its own duty, so the draw takes them as it takes anyone: one bot
/// seat each, and none of them holding enough of the deck to subtract
/// the rest. They are all ours, which is the bend doc 04 names — ours
/// rather than another player's, and only when the room is empty.
class LastResortBench {
  LastResortBench({
    required List<Signer> signers,
    required List<Uri> relays,
    void Function(String line)? log,
    int idleMs = 10 * 60 * 1000,
    int silenceAfterMs = 120000,
    DealCrypto? crypto,
  }) : jurors = [
          for (final s in signers)
            LastResortJuror(relays: relays, signer: s, log: log, idleMs: idleMs, silenceAfterMs: silenceAfterMs, crypto: crypto),
        ];

  final List<LastResortJuror> jurors;

  /// Whether any of the bench is up.
  bool get online => jurors.any((j) => j.online);

  void start() {
    for (final j in jurors) {
      j.start();
    }
  }

  void close() {
    for (final j in jurors) {
      j.close();
    }
  }
}

/// The juror of last resort (docs/04-live-play.md): quiet until a
/// table says it has nobody to draw from, then online — the same code
/// every other juror runs — and quiet again once it has been idle for
/// a while.
class LastResortJuror {
  LastResortJuror(
      {required this.relays, required this.signer, this.log, this.idleMs = 10 * 60 * 1000, int silenceAfterMs = 120000, DealCrypto? crypto}) {
    presence = RelayPresence(relays: relays, signer: signer, status: 'last-resort', log: log)..silent = true;
    duty = JurorDuty(relays: relays, signer: signer, presence: presence, log: log, silenceAfterMs: silenceAfterMs, crypto: crypto);
  }

  final List<Uri> relays;
  final Signer signer;
  final void Function(String line)? log;

  /// How long to stay online after the last call with nothing to serve.
  final int idleMs;

  late final RelayPresence presence;
  late final JurorDuty duty;
  StreamSubscription<String>? _calls;
  Timer? _idle;
  int _calledAt = 0;
  bool online = false;

  void start() {
    duty.start();
    _calls = presence.calls.listen(_onCall);
    _idle = Timer.periodic(const Duration(seconds: 30), (_) => _checkIdle());
  }

  void _onCall(String table) {
    _calledAt = DateTime.now().millisecondsSinceEpoch;
    if (online) return;
    online = true;
    presence.silent = false;
    log?.call('called for by $table; online');
  }

  void _checkIdle() {
    if (!online || duty.serving > 0) return;
    if (DateTime.now().millisecondsSinceEpoch - _calledAt < idleMs) return;
    online = false;
    presence.silent = true;
    log?.call('idle; quiet again');
  }

  void close() {
    _calls?.cancel();
    _idle?.cancel();
    duty.close();
    presence.close();
  }
}
