/// Watching a game being played, from its address (router.dart,
/// `/play/table/ID`; packages/table, watch.dart).
///
/// The watcher reads the table's watch lane on our relay and says every
/// [WatchBroadcast.again] that it is there; a seated player's device
/// answers with the table as anyone at it sees it. Watching is live
/// play, which is a subscription's: it is said by this device's own key,
/// with its licence, and only the account's device in use is carried on
/// the relay at all (net/in_use.dart). The answering device turns away
/// a watcher of an account seated at its table: nobody watches their own
/// game from another device.
library;

import 'dart:async';

import 'package:table/table.dart';

import '../entitlement.dart';
import '../identity.dart';
import 'relays.dart';

/// How a table is watched: the relay's, and a test's to replace.
Stream<WatchedTable> Function(String table) watchTable = _watch;

Stream<WatchedTable> _watch(String table) {
  late final StreamController<WatchedTable> out;
  RelayTransport? relay;
  Timer? again;
  StreamSubscription<void>? heard;
  var seq = -1;
  var gone = false;
  void stop() {
    gone = true;
    again?.cancel();
    heard?.cancel();
    relay?.close();
  }

  out = StreamController<WatchedTable>(
    onListen: () async {
      final signer = await Identity.signer();
      if (gone) return;
      final r = relay = RelayTransport(relays: appRelays(), signer: signer, table: table, watchOnly: true);
      heard = r.watch.listen((m) {
        final v = WatchedTable.parse(m.content['view'], table: table);
        // An older view than one shown, from a device a move behind: old news.
        if (v == null || v.seq < seq) return;
        seq = v.seq;
        out.add(v);
      });
      final licence = Entitlement.current.licence;
      void watching() => r.sayWatch({'watching': true, if (licence != null) 'licence': licence.toJson()});
      unawaited(r.ready.then((_) => watching(), onError: (_) {}));
      again = Timer.periodic(WatchBroadcast.again, (_) => watching());
    },
    onCancel: stop,
  );
  return out.stream;
}
