/// Nostr events and filters — the subset of NIP-01 the table uses.
///
/// A Nostr event is a signed, content-addressed record: its id is the
/// SHA-256 of a canonical serialisation, its signature is BIP-340 over
/// that id, and any relay or peer can check both. The table's own
/// events (events.dart) are the same shape one level down; on a relay
/// they travel inside one of these, signed by whoever sent it — which
/// is what lets a peer tell "heard from" apart from "heard about".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';

class NostrEvent {
  NostrEvent._({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// Builds, hashes and signs.
  factory NostrEvent.sign(
    Signer signer, {
    required int kind,
    required String content,
    List<List<String>> tags = const [],
    int? createdAt,
  }) {
    final at = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = digestOf(canonical(signer.publicKey, at, kind, tags, content));
    return NostrEvent._(
      id: id,
      pubkey: signer.publicKey,
      createdAt: at,
      kind: kind,
      tags: [for (final t in tags) List.unmodifiable(t)],
      content: content,
      sig: signer.sign(id),
    );
  }

  /// Parses and checks. Null for anything malformed, misidentified or
  /// not signed by its claimed author.
  static NostrEvent? parse(Object? json) {
    try {
      final m = json as Map;
      final pubkey = m['pubkey'] as String;
      final createdAt = m['created_at'] as int;
      final kind = m['kind'] as int;
      final tags = [for (final t in m['tags'] as List) [for (final s in t as List) s as String]];
      final content = m['content'] as String;
      final sig = m['sig'] as String;
      final id = digestOf(canonical(pubkey, createdAt, kind, tags, content));
      if (id != m['id']) return null;
      if (!verify(pubkey, id, sig)) return null;
      return NostrEvent._(
        id: id,
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: [for (final t in tags) List.unmodifiable(t)],
        content: content,
        sig: sig,
      );
    } catch (_) {
      return null;
    }
  }

  final String id;
  final PublicKey pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  /// NIP-01: the id is the SHA-256 of
  /// `[0, pubkey, created_at, kind, tags, content]` as compact JSON.
  static Uint8List canonical(PublicKey pubkey, int createdAt, int kind, List<List<String>> tags, String content) =>
      Uint8List.fromList(utf8.encode(jsonEncode([0, pubkey, createdAt, kind, tags, content])));

  /// The first value of the first tag named [name], if any.
  String? tag(String name) {
    for (final t in tags) {
      if (t.length >= 2 && t[0] == name) return t[1];
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  /// Kinds 20000–29999 are ephemeral: a relay forwards and forgets.
  bool get ephemeral => kind >= 20000 && kind < 30000;

  @override
  String toString() => 'kind $kind by ${pubkey.substring(0, 6)} #${id.substring(0, 6)}';
}

/// A NIP-01 filter: every listed condition must hold; a list matches
/// any of its values; `#x` matches events with a tag `x` of any of the
/// values.
class Filter {
  const Filter({this.ids, this.authors, this.kinds, this.since, this.until, this.limit, this.tags = const {}});

  final List<String>? ids;
  final List<String>? authors;
  final List<int>? kinds;
  final int? since;
  final int? until;
  final int? limit;

  /// Tag name (one letter) to accepted values.
  final Map<String, List<String>> tags;

  static Filter? parse(Object? json) {
    try {
      final m = json as Map;
      final tags = <String, List<String>>{};
      for (final e in m.entries) {
        final k = e.key as String;
        if (k.length == 2 && k.startsWith('#')) tags[k.substring(1)] = [for (final v in e.value as List) v as String];
      }
      List<String>? strings(String key) => m[key] == null ? null : [for (final v in m[key] as List) v as String];
      return Filter(
        ids: strings('ids'),
        authors: strings('authors'),
        kinds: m['kinds'] == null ? null : [for (final v in m['kinds'] as List) v as int],
        since: m['since'] as int?,
        until: m['until'] as int?,
        limit: m['limit'] as int?,
        tags: tags,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
        if (ids != null) 'ids': ids,
        if (authors != null) 'authors': authors,
        if (kinds != null) 'kinds': kinds,
        if (since != null) 'since': since,
        if (until != null) 'until': until,
        if (limit != null) 'limit': limit,
        for (final e in tags.entries) '#${e.key}': e.value,
      };

  bool matches(NostrEvent e) {
    if (ids != null && !ids!.any(e.id.startsWith)) return false;
    if (authors != null && !authors!.any(e.pubkey.startsWith)) return false;
    if (kinds != null && !kinds!.contains(e.kind)) return false;
    if (since != null && e.createdAt < since!) return false;
    if (until != null && e.createdAt > until!) return false;
    for (final t in tags.entries) {
      if (!e.tags.any((x) => x.length >= 2 && x[0] == t.key && t.value.contains(x[1]))) return false;
    }
    return true;
  }
}

/// The kinds the table uses. Ephemeral, all of them: a relay forwards
/// them to whoever is listening and keeps nothing, and the table's own
/// repeat-and-catch-up is what recovers a dropped message.
abstract final class TableKinds {
  /// A table event (events.dart) as the content, tagged `t` with the
  /// table id. Signed by the sender, who may be relaying.
  static const table = 24242;

  /// WebRTC signalling — an offer, answer or ICE candidate — tagged `p`
  /// with the recipient and `t` with the table id.
  static const signal = 24243;

  /// The lobby: hosting a table, joining it, starting it, tagged `t`
  /// with the room code. Stored, not ephemeral, so a relay hands a
  /// joiner the room that was announced before it arrived.
  static const lobby = 4244;
}
