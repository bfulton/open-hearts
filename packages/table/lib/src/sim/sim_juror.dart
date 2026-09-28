/// A stranger online who can be drawn: summoned, it follows the
/// table from wherever it is and answers appeals; it can go the way a
/// person can — quietly, by crashing, or by simply stopping.
library;

import 'dart:math';

import 'package:deal/deal.dart';

import '../client.dart';
import '../juror_duty.dart';
import '../signing.dart';
import '../spec.dart';
import 'scripted_human.dart';
import 'sim_network.dart';
import 'virtual_clock.dart';

class SimJuror {
  SimJuror(this.signer, this.net, this.clock, {this.crypto});

  final FakeSigner signer;
  final SimNetwork net;
  final VirtualClock clock;
  final DealCrypto? crypto;

  /// The client following the table, from the first summons on.
  TableClient? client;

  /// Where this juror's clients write their trace, for a test to read.
  void Function(String line)? log;

  /// Whether the client is let go of once the table has moved past
  /// every hand it was summoned to, as the duty does every ten seconds
  /// (juror_duty.dart). A later summons to the same table then starts a
  /// client afresh, which reads the record from the first hand — with
  /// nothing of what the one before it drew.
  bool sweeps = false;

  /// Clients let go of that way, for tests.
  int swept = 0;

  /// How far each table's client had got when it was let go of, as the
  /// duty keeps it, and the summonses to hands before that it started
  /// no client for.
  final letGo = LetGo();
  int stale = 0;

  /// The hand each of this juror's clients was started by a summons
  /// to, in order: more than one is a juror summoned again after its
  /// client was let go of.
  final List<int> startedFor = [];

  /// What this juror's clients, the ones let go of included, would
  /// have said about a hand before their summons ([TableClient]).
  int get saidBeforeSummons => _saidBefore + (client?.saidBeforeSummons ?? 0);
  int _saidBefore = 0;

  Exit? exit;
  bool gone = false;

  /// For a juror of last resort: whether a table has called for it.
  bool called = false;

  /// The verdicts this juror gave, for tests.
  int verdicts = 0;

  void summoned(TableSpec spec, int hand, List<PublicKey> jurors, {String? juryId, bool first = false}) {
    if (gone) return;
    var c = client;
    if (c == null && letGo.stale(spec.id, hand)) {
      stale++;
      return;
    }
    if (c == null || c.spec.id != spec.id) {
      c?.close();
      // A client of its own draws, as a new process's are: one seeded
      // like the last would draw the secrets that one drew, and the
      // audit of an early hand would open a later one.
      c = TableClient(
          spec: spec,
          signer: signer,
          transport: net.attach(signer.publicKey),
          clock: clock,
          crypto: crypto,
          random: Random(signer.publicKey.hashCode + startedFor.length));
      c.log = log;
      client = c;
      startedFor.add(hand);
      c.start();
      if (sweeps) _sweep(c);
      c.changes.listen((_) => verdicts = c!.record.where((d) => d.verdict?.author == signer.publicKey).length);
    }
    c.serveFor(hand, jurors, juryId: juryId, first: first);
  }

  void _sweep(TableClient c) {
    clock.schedule(10000, () {
      if (client != c) return;
      if (c.serving) return _sweep(c);
      _saidBefore += c.saidBeforeSummons;
      letGo.record(c.spec.id, c.game.handNumber);
      c.close();
      net.detach(signer.publicKey, c.transport as SimTransport);
      client = null;
      swept++;
    });
  }

  /// Goes, by [how]: a leave is just no longer serving; a crash and a
  /// quiet spell are the network's.
  void depart(Exit how) {
    if (gone) return;
    gone = true;
    exit = how;
    switch (how) {
      case Exit.leave:
        client?.stopServing();
      case Exit.crash:
        net.crash(signer.publicKey);
      case Exit.idle:
        net.goOffline(signer.publicKey);
    }
  }

  void stop() {
    client?.close();
  }
}
