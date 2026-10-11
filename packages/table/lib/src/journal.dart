/// What a seated device must remember of a table to come back to it:
/// everything it has signed there, and the secret each hand's deal
/// keys were made from.
///
/// A device that reloads mid-game loses the client and everything in
/// it; the others hold the record and carry anyone behind forward
/// (client.dart, catch-up), but two things only this device ever had.
/// Its own word: every move and every vote it signed, which it must
/// not contradict — a side backs one way at a turn, never both — and
/// which it would, signing afresh at a turn it had already spoken at.
/// And its deal secret: the keys on the record were made from it, and
/// a seat that comes back with another cannot open its own cards.
///
/// So the client writes both here as it goes ([said], [keep]) and,
/// built again from them, reads its own word back before it says
/// anything new ([TableClient.start]). Kept on the device and nowhere
/// else (app: net/seat_store.dart); a heartbeat is not kept, being only
/// "still here".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'events.dart';

class TableJournal {
  TableJournal({List<Map<String, Object?>>? said, Map<int, Uint8List>? secrets})
      : _said = said ?? [],
        _secrets = secrets ?? {};

  final List<Map<String, Object?>> _said;
  final Map<int, Uint8List> _secrets;
  final Set<String> _ids = {};

  /// Called as each event is added, before it goes anywhere: whoever
  /// keeps the journal writes it then, so that no event the table has
  /// heard is one a reload can forget.
  void Function(Map<String, Object?> event)? onSaid;

  /// Called as a hand's secret is kept.
  void Function(int hand, Uint8List secret)? onKept;

  /// Everything this device signed at the table, in the order it did.
  List<Map<String, Object?>> get saidSoFar => List.unmodifiable(_said);

  /// The secret this device's keys for [hand] were made from, if it
  /// made any.
  Uint8List? secretFor(int hand) => _secrets[hand];

  void said(TableEvent event) {
    if (event.kind == EventKind.heartbeat || event.kind == EventKind.serve) return;
    if (_ids.isEmpty && _said.isNotEmpty) _ids.addAll(_said.map((e) => e['id'] as String));
    if (!_ids.add(event.id)) return;
    final json = event.toJson();
    _said.add(json);
    onSaid?.call(json);
  }

  void keep(int hand, Uint8List secret) {
    final had = _secrets[hand];
    if (had != null && _same(had, secret)) return;
    _secrets[hand] = Uint8List.fromList(secret);
    onKept?.call(hand, _secrets[hand]!);
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
        'said': _said,
        'secrets': {for (final e in _secrets.entries) '${e.key}': base64.encode(e.value)},
      };

  /// As [toJson] wrote it, or null for anything else.
  static TableJournal? parse(Object? json) {
    try {
      final m = json as Map;
      return TableJournal(
        said: [for (final e in m['said'] as List) Map<String, Object?>.from(e as Map)],
        secrets: {
          for (final e in (m['secrets'] as Map).entries) int.parse(e.key as String): Uint8List.fromList(base64.decode(e.value as String)),
        },
      );
    } catch (_) {
      return null;
    }
  }
}
