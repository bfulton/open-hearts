/// Serving as a juror: the client any player's app runs in the
/// background, and the one the service runs as juror of last resort.
///
/// A summons names a table and a hand. The duty opens a client on that
/// table's tag — following, not seated — tells it which hand and which
/// jury it was drawn into, and closes it once the table has moved past
/// every hand it served. Several tables at once are several clients.
library;

import 'dart:async';

import 'client.dart';
import 'clock.dart';
import 'presence_relay.dart';
import 'relay_transport.dart';
import 'signing.dart';

class JurorDuty {
  JurorDuty({required this.url, required this.signer, required this.presence, this.log, Clock? clock, this.silenceAfterMs = 120000})
      : clock = clock ?? WallClock();

  final Uri url;
  final Signer signer;
  final RelayPresence presence;
  final void Function(String line)? log;
  final Clock clock;

  /// The silence a juror's clients count as absence; the protocol's
  /// two minutes, shorter in a test.
  final int silenceAfterMs;

  final Map<String, ({TableClient client, RelayTransport transport})> _tables = {};
  StreamSubscription<Summons>? _sub;
  Timer? _sweep;

  /// Tables this client is following as a juror.
  int get serving => _tables.length;

  /// Verdicts given, over every table.
  int verdicts = 0;

  void start() {
    _sub = presence.summonses.listen(_onSummons);
    _sweep = Timer.periodic(const Duration(seconds: 10), (_) => _sweepTables());
  }

  void _onSummons(Summons s) {
    var t = _tables[s.spec.id];
    if (t == null) {
      final transport = RelayTransport(url: url, signer: signer, table: s.spec.id, log: log);
      final client = TableClient(spec: s.spec, signer: signer, transport: transport, clock: clock, silenceAfterMs: silenceAfterMs);
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

/// The juror of last resort (docs/04-live-play.md): quiet until a
/// table says it has nobody to draw from, then online — the same code
/// every other juror runs — and quiet again once it has been idle for
/// a while.
class LastResortJuror {
  LastResortJuror({required this.url, required this.signer, this.log, this.idleMs = 10 * 60 * 1000, int silenceAfterMs = 120000}) {
    presence = RelayPresence(url: url, signer: signer, status: 'last-resort', log: log)..silent = true;
    duty = JurorDuty(url: url, signer: signer, presence: presence, log: log, silenceAfterMs: silenceAfterMs);
  }

  final Uri url;
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
