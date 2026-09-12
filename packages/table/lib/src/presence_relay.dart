/// Presence over the relays: who is online, and a summons to a juror.
///
/// Every client with the app open says so on one well-known tag every
/// few seconds — an ephemeral event, forwarded and forgotten — and
/// everyone listening keeps a map of who was heard when. A summons is
/// an event on the same tag addressed to one key, carrying the table's
/// spec and the hand; a juror of last resort listens for a table's
/// call on the tag as well. Its own sockets, apart from any table's:
/// one to every relay in the list, the announcements written to one of
/// them (relays.dart).
library;

import 'dart:async';
import 'dart:convert';

import 'jury.dart';
import 'nostr.dart';
import 'relays.dart';
import 'signing.dart';
import 'spec.dart';

/// A summons as a juror receives it.
class Summons {
  const Summons({required this.spec, required this.hand, required this.jurors, required this.from});
  final TableSpec spec;
  final int hand;
  final List<PublicKey> jurors;
  final PublicKey from;

  static Summons? parse(PublicKey from, Map<String, Object?> content) {
    try {
      final spec = TableSpec.parse(content['table']);
      if (spec == null) return null;
      return Summons(
        spec: spec,
        hand: content['hand'] as int,
        jurors: [for (final k in content['jurors'] as List) k as String],
        from: from,
      );
    } catch (_) {
      return null;
    }
  }
}

class RelayPresence implements Presence {
  RelayPresence({required List<Uri> relays, required this.signer, this.status = 'online', this.everyMs = 5000, this.log})
      : relays = Relays.turnedBy(relays, signer.publicKey) {
    _group = RelayGroup(
      urls: this.relays,
      subscriptions: {
        'online': [const Filter(kinds: [TableKinds.presence]).toJson()..['#t'] = [topic]],
      },
      onEvent: _onEvent,
      log: log,
    );
    _group.ready.then((_) {
      if (_closed) return;
      _announce();
      log?.call('presence on ${this.relays.join(', ')}');
    });
    _beat = Timer.periodic(Duration(milliseconds: everyMs), (_) => _announce());
  }

  /// The relays, in the order this client writes to them.
  final List<Uri> relays;
  final Signer signer;

  /// What this client says of itself: `online`, or `last-resort` for
  /// the juror a service brings up.
  String status;
  final int everyMs;
  final void Function(String line)? log;

  static const topic = 'online';

  late final RelayGroup _group;
  final Map<PublicKey, int> _seen = {};
  final _summonses = StreamController<Summons>.broadcast();
  final _calls = StreamController<String>.broadcast();
  Timer? _beat;
  bool _closed = false;
  bool _silent = false;

  /// Summonses addressed to this key.
  Stream<Summons> get summonses => _summonses.stream;

  /// Tables that said they had nobody to draw from.
  Stream<String> get calls => _calls.stream;

  /// Resolves once some relay has acknowledged the subscription.
  Future<void> get ready => _group.ready;

  /// The reason the last relay gave when every relay refused this
  /// client's latest announcement; null once one takes it again.
  String? get refusal => _group.refusal;

  /// Stops announcing, while still listening — a juror of last resort
  /// stays quiet until called.
  set silent(bool v) => _silent = v;

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  Set<PublicKey> online({required int withinMs}) {
    final now = _nowMs;
    return {for (final e in _seen.entries) if (now - e.value < withinMs) e.key, if (!_silent) signer.publicKey};
  }

  @override
  void summon(PublicKey juror, Map<String, Object?> summons) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'summons', ...summons}), tags: [
      ['t', topic],
      ['p', juror],
    ]));
  }

  @override
  void callForJuror(String table) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'call', 'table': table}), tags: [
      ['t', topic],
    ]));
  }

  void _announce() {
    if (_silent || _closed) return;
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'here', 'status': status}), tags: [
      ['t', topic],
    ]));
  }

  bool _onEvent(Map<String, Object?> raw) {
    final e = NostrEvent.parse(raw);
    if (e == null || e.kind != TableKinds.presence || e.tag('t') != topic) return false;
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return true;
    }
    switch (c['kind']) {
      case 'here':
        _seen[e.pubkey] = _nowMs;
      case 'summons':
        if (e.tag('p') != signer.publicKey) return true;
        final s = Summons.parse(e.pubkey, c);
        if (s != null) _summonses.add(s);
      case 'call':
        if (c['table'] is String) _calls.add(c['table'] as String);
    }
    return true;
  }

  void close() {
    _closed = true;
    _beat?.cancel();
    _group.close();
    _summonses.close();
    _calls.close();
  }
}
