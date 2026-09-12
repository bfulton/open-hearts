/// A stranger online who can be drawn: summoned, it follows the
/// table from wherever it is and answers appeals; it can go the way a
/// person can — quietly, by crashing, or by simply stopping.
library;

import 'package:deal/deal.dart';

import '../client.dart';
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

  Exit? exit;
  bool gone = false;

  /// For a juror of last resort: whether a table has called for it.
  bool called = false;

  /// The verdicts this juror gave, for tests.
  int verdicts = 0;

  void summoned(TableSpec spec, int hand, List<PublicKey> jurors) {
    if (gone) return;
    var c = client;
    if (c == null || c.spec.id != spec.id) {
      c?.close();
      c = TableClient(spec: spec, signer: signer, transport: net.attach(signer.publicKey), clock: clock, crypto: crypto);
      client = c;
      c.start();
      c.changes.listen((_) => verdicts = c!.record.where((d) => d.verdict?.author == signer.publicKey).length);
    }
    c.serveFor(hand, jurors);
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
