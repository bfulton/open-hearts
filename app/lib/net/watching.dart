/// Watching a game being played, from its address (router.dart,
/// `/table/ID`; packages/table, watch.dart).
///
/// The watcher reads the table's watch lane on our relay and says every
/// [WatchBroadcast.again] that it is there; a seated player's device
/// answers with the table as anyone at it sees it. Watching is live
/// play, which is a subscription's: it is said by this device's own key,
/// with its licence, and only the account's device in use is carried on
/// the relay at all (net/in_use.dart). The answering device turns away
/// a watcher of an account seated at its table: nobody watches their own
/// game from another device.
///
/// The players' reactions come by the same lane (packages/table,
/// reactions.dart), each as it was said, for the page to hold to the
/// rules against the seats the latest view names. A watcher has none to
/// send.
library;

import 'dart:async';

import 'package:table/table.dart';

import '../entitlement.dart';
import '../identity.dart';
import 'relays.dart';

/// What a watched table says: a view of it, or a player's reaction.
sealed class Watched {
  const Watched();
}

/// The table as a seated player's device tells it.
class Viewed extends Watched {
  const Viewed(this.view);
  final WatchedTable view;
}

/// A reaction as it arrived, not yet believed: the page holds it to
/// [ReactionRules] against the seats of the view it is showing.
class Reacted extends Watched {
  const Reacted(this.heard);
  final HeardReaction heard;
}

/// How a table is watched: the relay's, and a test's to replace.
Stream<Watched> Function(String table) watchTable = _watch;

Stream<Watched> _watch(String table) {
  late final StreamController<Watched> out;
  RelayTransport? relay;
  Timer? again;
  StreamSubscription<void>? heard;
  StreamSubscription<void>? reacted;
  var seq = -1;
  var gone = false;
  void stop() {
    gone = true;
    again?.cancel();
    heard?.cancel();
    reacted?.cancel();
    relay?.close();
  }

  out = StreamController<Watched>(
    onListen: () async {
      final signer = await Identity.signer();
      if (gone) return;
      final r = relay = RelayTransport(relays: appRelays(), signer: signer, table: table, watchOnly: true);
      heard = r.watch.listen((m) {
        final v = WatchedTable.parse(m.content['view'], table: table);
        // An older view than one shown, from a device a move behind: old news.
        if (v == null || v.seq < seq) return;
        seq = v.seq;
        out.add(Viewed(v));
      });
      reacted = r.reactions.listen((h) => out.add(Reacted(h)));
      final licence = Entitlement.current.licence;
      void watching() => r.sayWatch({'watching': true, if (licence != null) 'licence': licence.toJson()});
      unawaited(r.ready.then((_) => watching(), onError: (_) {}));
      again = Timer.periodic(WatchBroadcast.again, (_) => watching());
    },
    onCancel: stop,
  );
  return out.stream;
}
