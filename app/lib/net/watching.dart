/// Watching a game being played, from its address (router.dart,
/// `/play/table/ID`; packages/table, watch.dart).
///
/// The watcher reads the table's watch lane on our relay and says every
/// [WatchBroadcast.again] that it is there; a seated player's device
/// answers with the table as anyone at it sees it. Under a key made for
/// the watching and thrown away after, so watching a game says nothing
/// about who watched.
library;

import 'dart:async';
import 'dart:math';

import 'package:table/table.dart';

import '../crypto/schnorr.dart';
import 'relays.dart';

/// How a table is watched: the relay's, and a test's to replace.
Stream<WatchedTable> Function(String table) watchTable = _watch;

Stream<WatchedTable> _watch(String table) {
  late final StreamController<WatchedTable> out;
  RelayTransport? relay;
  Timer? again;
  StreamSubscription<void>? heard;
  var seq = -1;
  void stop() {
    again?.cancel();
    heard?.cancel();
    relay?.close();
  }

  out = StreamController<WatchedTable>(
    onListen: () {
      final rng = Random.secure();
      final secret = List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final r = relay = RelayTransport(relays: appRelays(), signer: signerFromSecret(secret), table: table, watchOnly: true);
      heard = r.watch.listen((m) {
        final v = WatchedTable.parse(m.content['view'], table: table);
        // An older view than one shown, from a device a move behind: old news.
        if (v == null || v.seq < seq) return;
        seq = v.seq;
        out.add(v);
      });
      void watching() => r.sayWatch({'watching': true});
      unawaited(r.ready.then((_) => watching(), onError: (_) {}));
      again = Timer.periodic(WatchBroadcast.again, (_) => watching());
    },
    onCancel: stop,
  );
  return out.stream;
}
