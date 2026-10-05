/// Presence over the relays: who is online, and a summons to a juror.
///
/// Every client with the app open says so on one well-known tag every
/// few seconds — an ephemeral event, forwarded and forgotten — and
/// everyone listening keeps a map of who was heard when. A summons is
/// an event on the same tag addressed to one key, carrying the table's
/// spec and the hand; a juror of last resort listens for a table's
/// call on the tag as well. Its own sockets, apart from any table's:
/// one to every relay in the list, the announcements written to all
/// of them, since who is online has to be seen by devices that can
/// read only some of the relays (relays.dart).
///
/// A relay that keeps an object per tag ([tagMark], docs/06-service.md)
/// takes the tag in its URL, and presence puts its own there. The
/// announcements go to every relay in the list: a device is online for
/// whoever can hear it, and what another device can hear is not
/// assumed.
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
  const Summons(
      {required this.spec,
      required this.hand,
      required this.jurors,
      required this.from,
      this.juryId,
      this.first = false,
      this.draws = const []});
  final TableSpec spec;
  final int hand;
  final List<PublicKey> jurors;
  final PublicKey from;

  /// The jury event this summons names, where the sender said which.
  final String? juryId;

  /// Whether that event is the *first* jury drawn for [hand], as the
  /// sender's record has it. A bot seat's holder is read from the
  /// hand's first jury and no other, so a juror can act on the list
  /// in a first summons before the event reaches it — and must not
  /// act on the list in a redraw, which names the jury as it stands
  /// now rather than the one the seats were dealt to.
  final bool first;

  /// The draws the sender's table had carried for [hand], each with
  /// the witnesses that carried it, as signed events
  /// ([TableClient.serveFor]).
  final List<Map<String, Object?>> draws;

  static Summons? parse(PublicKey from, Map<String, Object?> content) {
    try {
      final spec = TableSpec.parse(content['table']);
      if (spec == null) return null;
      return Summons(
        spec: spec,
        hand: content['hand'] as int,
        jurors: [for (final k in content['jurors'] as List) k as String],
        from: from,
        juryId: content['jury'] as String?,
        first: content['first'] == true,
        draws: [
          for (final d in content['draws'] as List? ?? const [])
            if (d is Map) Map<String, Object?>.from(d),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// The mark a relay wears in the list when it keeps one object per tag
/// and wants the tag in the URL: `wss://our.relay/{tag}`.
///
/// It has to be marked and cannot be guessed at, in either direction.
/// A relay that serves every tag on one socket at the root answers a
/// path with a 404, so a client must not put a tag on one; a
/// relay that shards has to be told which object to open before the
/// first message crosses, so a client must put the tag on that one.
/// Nobody else's URL carries the mark, so the list says which is which
/// and nothing has to be inferred from a hostname.
///
/// The other half of the rule: a client with no tag cannot use a
/// marked relay at all, so a list handed to one must not carry it.
/// Tables and signalling still take the ordinary list
/// (`app/lib/net/relays.dart`, `relay_transport.dart`).
const tagMark = '{tag}';

/// [relays] with [tag] put where each marked relay asks for it; every
/// other relay is left exactly as it was.
List<Uri> relaysForTag(List<Uri> relays, String tag) => [
      for (final relay in relays)
        if (relay.pathSegments.contains(tagMark))
          relay.replace(pathSegments: [for (final s in relay.pathSegments) s == tagMark ? tag : s])
        else
          relay,
    ];

class RelayPresence implements Presence {
  RelayPresence(
      {required List<Uri> relays, required this.signer, this.status = 'online', this.everyMs = 5000, this.canServe, this.log})
      : relays = Relays.turnedBy(relaysForTag(relays, topic), signer.publicKey) {
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

  /// Whether this device can serve as a juror at the tables that would
  /// draw it — for the app, whether its deal loaded and its worker has
  /// not failed for good since. Every live table is sealed, so one that
  /// cannot deal cannot serve any of them, and drawn it would hold a
  /// bot seat and a piece of every escrow it never answers for. While
  /// this is false the device says nothing of itself, and if it had
  /// said it was here it says it is going; it still listens. Read at
  /// every beat, so a device that stops being able to is gone for
  /// everyone within one. Null is always.
  final bool Function()? canServe;
  final void Function(String line)? log;

  static const topic = 'online';

  late final RelayGroup _group;
  final Map<PublicKey, int> _seen = {};

  /// When each key's current run of being here began, and what it
  /// last said it was doing — the two things [settled] reads.
  final Map<PublicKey, int> _since = {};
  final Map<PublicKey, String> _doing = {};

  /// Keys that have said they are going. A device that closes says so
  /// rather than leaving everyone to notice a missed heartbeat, which
  /// is five seconds of the table believing somebody is there who is
  /// not. Only the key itself can say it, since the event is signed
  /// by it, and a later `here` undoes it.
  final Set<PublicKey> _went = {};

  /// A run shorter than this is a fresh arrival rather than a return:
  /// long enough to ride out one missed announcement, short enough
  /// that somebody back from a real absence starts their run again.
  static const _gapMs = 15000;

  /// Whether this device has said it is here since it last said it
  /// was going.
  bool _announced = false;

  bool get _able => canServe?.call() ?? true;

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
    return {
      for (final e in _seen.entries)
        if (now - e.value < withinMs && !_went.contains(e.key)) e.key,
      if (!_silent && _able) signer.publicKey,
    };
  }

  @override
  Set<PublicKey> settled({required int withinMs, required int forMs}) {
    final now = _nowMs;
    return {
      for (final k in online(withinMs: withinMs))
        if (k == signer.publicKey || _doing[k] == seated || now - (_since[k] ?? now) >= forMs) k,
    };
  }

  /// What a client says of itself while it is at a table, as against
  /// the lobby: somebody mid-game has a reason to still be here in a
  /// minute.
  static const seated = 'seated';

  /// Says this device is going, so that nobody waits out a heartbeat
  /// to find out. Best effort by its nature — a backgrounded phone, a
  /// crash or a dead link says nothing at all — which is why the
  /// table still times out anyone silent.
  void leaving() {
    if (_closed || _silent) return;
    _sayGone();
    // And stop saying it is here, or the next beat would undo this.
    // Announcing resumes when something sets [silent] back.
    _silent = true;
  }

  void _sayGone() {
    _announced = false;
    _group.publish(
        NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'gone'}), tags: [
          ['t', topic],
        ]),
        everywhere: true);
  }

  @override
  void summon(PublicKey juror, Map<String, Object?> summons) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'summons', ...summons}), tags: [
      ['t', topic],
      ['p', juror],
    ]), everywhere: true);
  }

  @override
  void callForJuror(String table) {
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'call', 'table': table}), tags: [
      ['t', topic],
    ]), everywhere: true);
  }

  void _announce() {
    if (_silent || _closed) return;
    if (!_able) {
      if (_announced) {
        log?.call('presence: this device cannot serve as a juror; going');
        _sayGone();
      }
      return;
    }
    _announced = true;
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'here', 'status': status}), tags: [
      ['t', topic],
    ]), everywhere: true);
  }

  /// The newest presence each key has said, by its own clock, in
  /// seconds: anything older from that key is a replay.
  final Map<PublicKey, int> _newest = {};

  /// How old a presence event may be and still be news, in seconds: a
  /// few beats. Every presence event is public and any relay will take
  /// one again once it has forgotten its id, so an old `here` said again
  /// would make a device that left look online — long enough to be
  /// seated and booted — and an old `gone` would take a present one out
  /// (docs/security-review.md).
  int get _freshS => (everyMs * 4 ~/ 1000).clamp(20, 120);

  /// How far ahead of this device's clock an event may be dated: clocks
  /// drift, and no further than that.
  static const _aheadS = 60;

  /// Whether [e] is news: no older than a few beats, not from the
  /// future, and no older than what its key has already said.
  bool _fresh(NostrEvent e) {
    final nowS = _nowMs ~/ 1000;
    if (e.createdAt < nowS - _freshS || e.createdAt > nowS + _aheadS) return false;
    final newest = _newest[e.pubkey];
    if (newest != null && e.createdAt < newest) return false;
    _newest[e.pubkey] = e.createdAt;
    return true;
  }

  /// An event as it came off a relay: what the relays hand [_onEvent],
  /// for a test to hand it directly.
  bool receive(Map<String, Object?> raw) => _onEvent(raw);

  bool _onEvent(Map<String, Object?> raw) {
    final e = NostrEvent.parse(raw);
    if (e == null || e.kind != TableKinds.presence || e.tag('t') != topic) return false;
    if (!_fresh(e)) return true;
    Map<String, Object?> c;
    try {
      c = Map<String, Object?>.from(jsonDecode(e.content) as Map);
    } catch (_) {
      return true;
    }
    switch (c['kind']) {
      case 'here':
        final now = _nowMs;
        if (now - (_seen[e.pubkey] ?? -_gapMs * 2) > _gapMs) _since[e.pubkey] = now;
        _seen[e.pubkey] = now;
        _doing[e.pubkey] = c['status'] is String ? c['status'] as String : 'online';
        _went.remove(e.pubkey);
      case 'gone':
        _went.add(e.pubkey);
        _since.remove(e.pubkey);
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
