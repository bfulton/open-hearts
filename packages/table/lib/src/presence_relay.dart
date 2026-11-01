/// Presence over the relay: who has the app open, and whose device each
/// is.
///
/// Every client with the app open says so on one well-known tag every
/// few seconds — an ephemeral event, forwarded and forgotten — and
/// everyone listening keeps a map of who was heard when. That is how the
/// front door counts who is online, and how a device hears that another
/// device of its account has taken the account up.
///
/// A relay that keeps an object per tag ([tagMark], docs/explanation/service.md)
/// takes the tag in its URL, and presence puts its own there.
library;

import 'dart:async';
import 'dart:convert';

import 'licence.dart';
import 'nostr.dart';
import 'relays.dart';
import 'signing.dart';

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

class RelayPresence {
  RelayPresence({required List<Uri> relays, required this.signer, this.status = 'online', this.everyMs = 5000, this.activation, this.log})
      : relays = relaysForTag(relays, topic) {
    _group = RelayGroup(
      auth: relayAuthFor(signer),
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

  /// The relays, with presence's tag in each that asks for one.
  final List<Uri> relays;
  final Signer signer;

  /// What this client says of itself: `online`, or [seated].
  String status;
  final int everyMs;
  final void Function(String line)? log;

  /// This device's activation, as the service last gave it
  /// (licence.dart): said with every beat, so that everyone hears whose
  /// device this is, and another device of the same account hears that
  /// it has been superseded. Read at every beat.
  final Activation? Function()? activation;

  static const topic = 'online';

  /// What a client says of itself while it is at a table, as against
  /// the lobby.
  static const seated = 'seated';

  late final RelayGroup _group;
  final Map<PublicKey, int> _seen = {};

  /// Keys that have said they are going. A device that closes says so
  /// rather than leaving everyone to notice a missed heartbeat. Only the
  /// key itself can say it, since the event is signed by it, and a later
  /// `here` undoes it.
  final Set<PublicKey> _went = {};

  Timer? _beat;
  bool _closed = false;
  bool _silent = false;

  /// The account each key belongs to, as its activation says, and that
  /// activation's epoch.
  final Map<PublicKey, ({AccountId account, int epoch})> _accounts = {};

  /// The newest epoch heard for each account, and from which key.
  final Map<AccountId, ({PublicKey key, int epoch})> _newestOf = {};

  final _superseded = StreamController<Activation>.broadcast();

  /// A later activation of this device's own account, heard from
  /// another device: this one is no longer the account's in use
  /// (docs/explanation/service.md). The relay closes a superseded device's
  /// sockets itself; this is how a device hears it sooner.
  Stream<Activation> get superseded => _superseded.stream;

  /// The account [key] belongs to, as its activation says; the key
  /// itself for one that has said none.
  AccountId accountOf(PublicKey key) {
    if (key == signer.publicKey) {
      final mine = activation?.call();
      if (mine != null) return mine.account;
    }
    return _accounts[key]?.account ?? key;
  }

  /// Resolves once the relay has acknowledged the subscription.
  Future<void> get ready => _group.ready;

  /// The reason the relay gave when it refused this client's latest
  /// announcement; null once it takes one again.
  String? get refusal => _group.refusal;

  /// Stops announcing, while still listening.
  set silent(bool v) => _silent = v;

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// Who is online: heard from within [withinMs], not gone since, and
  /// not a device whose account another has taken up. This device, while
  /// it says it is here.
  Set<PublicKey> online({required int withinMs}) {
    final now = _nowMs;
    return {
      for (final e in _seen.entries)
        if (e.key != signer.publicKey && now - e.value < withinMs && !_went.contains(e.key) && !_outdone(e.key)) e.key,
      if (!_silent) signer.publicKey,
    };
  }

  /// Says this device is going, so that nobody waits out a heartbeat to
  /// find out. Best effort by its nature — a backgrounded phone, a crash
  /// or a dead link says nothing at all.
  void leaving() {
    if (_closed || _silent) return;
    _group.publish(NostrEvent.sign(signer, kind: TableKinds.presence, content: jsonEncode({'kind': 'gone'}), tags: [
      ['t', topic],
    ]));
    // And stop saying it is here, or the next beat would undo this.
    _silent = true;
  }

  /// Whether [key] is a device whose account has since been taken up by
  /// another: it is not online, whatever it last said.
  bool _outdone(PublicKey key) {
    final a = _accounts[key];
    if (a == null) return false;
    final newest = _newestOf[a.account];
    return newest != null && newest.key != key && newest.epoch > a.epoch;
  }

  void _announce() {
    if (_silent || _closed) return;
    final mine = activation?.call();
    _group.publish(NostrEvent.sign(signer,
        kind: TableKinds.presence,
        content: jsonEncode({'kind': 'here', 'status': status, if (mine != null) 'activation': mine.toJson()}),
        tags: [
          ['t', topic],
        ]));
  }

  /// What [key]'s beat says of its account: taken where it holds
  /// ([accountFrom]), and the newest epoch of each account kept, so a
  /// device superseded is out of [online] from the moment its successor
  /// is heard, and this device hears when it is the one superseded.
  void _account(PublicKey key, Object? said) {
    final act = Activation.parse(said);
    final account = accountFrom(act, key);
    if (act == null || account == null) return;
    _accounts[key] = (account: account, epoch: act.epoch);
    final newest = _newestOf[account];
    if (newest == null || act.epoch > newest.epoch || (act.epoch == newest.epoch && newest.key == key)) {
      _newestOf[account] = (key: key, epoch: act.epoch);
    }
    final mine = activation?.call();
    if (mine != null && key != signer.publicKey && act.supersedes(mine) && !_superseded.isClosed) _superseded.add(act);
  }

  /// The newest presence each key has said, by its own clock, in
  /// seconds: anything older from that key is a replay.
  final Map<PublicKey, int> _newest = {};

  /// How old a presence event may be and still be news, in seconds: a
  /// few beats. Every presence event is public and a relay will take one
  /// again once it has forgotten its id, so an old `here` said again
  /// would make a device that left look online, and an old `gone` would
  /// take a present one out (docs/explanation/security-model.md).
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

  /// An event as it came off the relay: what the relay hands [_onEvent],
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
        _account(e.pubkey, c['activation']);
        _seen[e.pubkey] = _nowMs;
        _went.remove(e.pubkey);
      case 'gone':
        _went.add(e.pubkey);
    }
    return true;
  }

  void close() {
    _closed = true;
    _beat?.cancel();
    _group.close();
    _superseded.close();
  }
}
