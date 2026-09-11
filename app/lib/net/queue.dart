/// Waiting to be matched: say so on the relay every few seconds, in
/// the pool chosen, until the matchmaker names a table with this key in
/// it. Nothing else to do; the matchmaker's rule is in
/// service/lib/src/matchmaker.dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:engine/engine.dart';
import 'package:table/table.dart';

class Queue extends ChangeNotifier {
  Queue({required this.relay, required this.pool, required this.name}) {
    _sub = relay.lobby.listen(_onLobby);
    _say();
    _beat = Timer.periodic(const Duration(seconds: 3), (_) {
      _say();
      notifyListeners(); // the clock on the screen
    });
  }

  /// The relay's tag for a pool's waiting room, as the matchmaker has it.
  static String poolTag(String pool) => 'queue:$pool';

  final RelayTransport relay;

  /// `rated` or `unrated`.
  final String pool;
  final String name;
  final int since = DateTime.now().millisecondsSinceEpoch;

  StreamSubscription<NostrEvent>? _sub;
  Timer? _beat;

  /// Set once the matchmaker has seated this player.
  TableSpec? spec;
  Map<int, String> seatNames = const {};

  int get waitedSeconds => (DateTime.now().millisecondsSinceEpoch - since) ~/ 1000;

  void _say() {
    if (spec == null) relay.announce({'kind': 'wait', 'name': name}, ephemeral: true);
  }

  void _onLobby(NostrEvent e) {
    if (e.kind != TableKinds.lobby || spec != null) return;
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return;
    }
    if (c['kind'] != 'match') return;
    final seats = <SeatHolder>[];
    final names = <int, String>{};
    var mine = false;
    var s = 0;
    for (final raw in c['seats'] as List) {
      final m = Map<String, Object?>.from(raw as Map);
      if (m['bot'] is String) {
        seats.add(BotSeat(Persona.named(m['bot'] as String)));
      } else {
        final key = m['key'] as String;
        if (key == relay.signer.publicKey) mine = true;
        seats.add(HumanSeat(key));
        names[s] = m['name'] as String? ?? 'Someone';
      }
      s++;
    }
    if (!mine || seats.length != seatCount) return;
    spec = TableSpec(id: c['table'] as String, seed: c['seed'] as int, seats: seats, rated: c['rated'] == true);
    seatNames = names;
    _beat?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _beat?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
