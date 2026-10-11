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
import 'spec.dart';
import 'transport.dart';

class JurorDuty {
  JurorDuty(
      {required this.relays,
      required this.signer,
      required this.presence,
      this.log,
      Clock? clock,
      this.silenceAfterMs,
      this.pinned = 0,
      this.dial,
      this.crypto,
      this.dealWorker})
      : clock = clock ?? WallClock();

  /// The relays a summoned client follows a table on; every one of
  /// them, whichever the table's peers write to (relays.dart).
  final List<Uri> relays;
  final Signer signer;
  final RelayPresence presence;
  final void Function(String line)? log;
  final Clock clock;

  /// The silence a juror's clients count as absence: null for each
  /// table's own ([TableTiming.silenceMs]), shorter in a test.
  final int? silenceAfterMs;

  /// The deal's primitives, to serve at sealed tables.
  final DealCrypto? crypto;

  /// Where the deal's slow calls are made for the tables served
  /// ([TableClient.dealWorker]); one for all of them, as a device has.
  final DealWorker? dealWorker;

  /// Relays at the front of [relays] kept primary.
  final int pinned;

  /// How a juror talks to the table it is summoned to. The default is
  /// the relay it was summoned over (docs/02-multiplayer.md). An app
  /// hands over a mesh instead: the relay under it for signalling, and
  /// a data channel to each seat, so a juror is dialled like anybody
  /// else at the table.
  ///
  /// The service's own jurors keep the relay, having no WebRTC in the
  /// VM to dial with.
  final Transport Function(TableSpec spec, RelayTransport relay)? dial;

  final Map<String, ({TableClient client, Transport transport})> _tables = {};

  /// How far each table's client had got when it was let go of.
  final letGo = LetGo();
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
    if (t == null && !_mayServe(s.spec)) return;
    if (t == null && letGo.stale(s.spec.id, s.hand)) {
      log?.call('summoned to ${s.spec.id} for hand ${s.hand}, which it had followed past: stale');
      return;
    }
    if (t == null) {
      final lane = RelayTransport(relays: relays, signer: signer, table: s.spec.id, log: log, pinned: pinned);
      final transport = dial?.call(s.spec, lane) ?? lane;
      if (s.spec.sealed && crypto == null) {
        log?.call('duty: summoned to a sealed table without the deal\'s cryptography; cannot serve');
        return;
      }
      if (s.spec.sealed && (dealWorker?.dead ?? false)) {
        log?.call('duty: summoned to a sealed table with the deal\'s worker failed for good; cannot serve');
        return;
      }
      final client =
          TableClient(spec: s.spec, signer: signer, transport: transport, clock: clock, silenceAfterMs: silenceAfterMs, crypto: crypto, dealWorker: dealWorker);
      client.log = log;
      t = _tables[s.spec.id] = (client: client, transport: transport);
      client.changes.listen((_) {
        verdicts = _tables.values.fold(0, (n, t) => n + t.client.record.where((d) => d.verdict?.author == signer.publicKey).length);
      });
      client.start();
      log?.call('summoned to ${s.spec.id} for hand ${s.hand} by ${s.from.substring(0, 6)}');
    }
    t.client.serveFor(s.hand, s.jurors, juryId: s.juryId, first: s.first, draws: s.draws);
  }

  /// Whether this device may follow [spec] as a juror at all: never a
  /// table its own account sits at — by whichever of its devices, since
  /// a juror there would be the player judging their own game — and
  /// never one whose seats are not the accounts they say they are
  /// (spec.dart, licence.dart).
  bool _mayServe(TableSpec spec) {
    final mine = presence.accountOf(signer.publicKey);
    if (spec.accounts.contains(mine)) {
      log?.call('summoned to ${spec.id}, where this device\'s own account sits: not served');
      return false;
    }
    final wrong = spec.licenceProblem(at: DateTime.now());
    if (wrong != null) {
      log?.call('summoned to ${spec.id}, whose seats do not check out ($wrong): not served');
      return false;
    }
    return true;
  }

  /// Where each table followed last moved, and when the juror last
  /// said why it has not since.
  final Map<String, ({int hand, int step, int movedAt, int toldAt})> _progress = {};

  void _sweepTables() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in List.of(_tables.entries)) {
      final c = e.value.client;
      // A line every ten seconds per table followed: where the juror
      // stands, for a log read after the fact.
      log?.call('following ${e.key}: hand ${c.game.handNumber} ${c.game.phase.name} step ${c.step} pause ${c.pause?.name} '
          'heartbeats ${c.heartbeatsSent} deferred ${c.deferred} serving ${c.serving}');
      // And a table that has not moved for a minute, once a minute: the
      // whole of what this side sees of it — whose turn, what is open,
      // what it holds back — so a stall can be read off the log rather
      // than guessed at.
      final was = _progress[e.key];
      if (was == null || was.hand != c.game.handNumber || was.step != c.step) {
        _progress[e.key] = (hand: c.game.handNumber, step: c.step, movedAt: now, toldAt: now);
      } else if (now - was.movedAt >= 60000 && now - was.toldAt >= 60000) {
        _progress[e.key] = (hand: was.hand, step: was.step, movedAt: was.movedAt, toldAt: now);
        log?.call('stalled ${e.key} for ${(now - was.movedAt) ~/ 1000}s:\n${c.describe()}');
      }
      if (c.serving) continue;
      log?.call('done with ${e.key}');
      _progress.remove(e.key);
      letGo.record(e.key, c.game.handNumber);
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

/// The tables a juror has been let go of, and the hand each had
/// reached by then.
///
/// A summons to a hand before that one is one a player sent from
/// behind: catching up on a jury it missed, it summons that jury's
/// jurors as if the hand were new. The client that could have served
/// the hand is gone, with every secret it drew for it. One started on
/// the summons would read the record from the first hand, find the
/// hand's seat held by its key, and take it for its own — and a client
/// holds nothing in a hand before its first summons, so no summons may
/// be the first that names a hand an earlier client had reached
/// ([TableClient.serveFor]).
class LetGo {
  final Map<String, int> _reached = {};

  void record(String table, int reached) => _reached[table] = reached;

  /// Whether a summons to [hand] of [table] names a hand a client here
  /// had already followed past.
  bool stale(String table, int hand) {
    final r = _reached[table];
    return r != null && hand < r;
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
/// the rest. They are all the service's, which docs/04-live-play.md
/// allows: the service's rather than another player's, and only when
/// the room is empty.
class LastResortBench {
  LastResortBench({
    required List<Signer> signers,
    required List<Uri> relays,
    List<Uri>? presenceRelays,
    void Function(String line)? log,
    int idleMs = 10 * 60 * 1000,
    int? silenceAfterMs,
    DealCrypto? crypto,
  }) : jurors = [
          for (final s in signers)
            LastResortJuror(
                relays: relays,
                presenceRelays: presenceRelays,
                signer: s,
                log: log,
                idleMs: idleMs,
                silenceAfterMs: silenceAfterMs,
                crypto: crypto),
        ];

  final List<LastResortJuror> jurors;

  /// Whether any of the bench is up.
  bool get online => jurors.any((j) => j.online);

  /// How many tables the bench is serving, counted once a juror.
  int get serving => jurors.fold(0, (n, j) => n + j.duty.serving);

  /// Called for by [table] some other way than on the relay — the
  /// service that woke this bench, passing the call on — so the bench
  /// is online for it now rather than at the table's next call.
  void wake(String table) {
    for (final j in jurors) {
      j.wake(table);
    }
  }

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
  /// [presenceRelays] are where it says it is here and hears the calls,
  /// as a device's presence is carried (app/lib/net/relays.dart,
  /// presenceRelays); [relays] where it follows the tables. The same
  /// list for both unless said.
  LastResortJuror(
      {required this.relays,
      List<Uri>? presenceRelays,
      required this.signer,
      this.log,
      this.idleMs = 10 * 60 * 1000,
      int? silenceAfterMs,
      DealCrypto? crypto}) {
    presence = RelayPresence(relays: presenceRelays ?? relays, signer: signer, status: 'last-resort', log: log)..silent = true;
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

  /// As a call heard on the relay.
  void wake(String table) => _onCall(table);

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
