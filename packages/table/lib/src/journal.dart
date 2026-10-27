/// What a seated device must remember of a table to come back to it: the
/// secret each hand's deal keys were made from.
///
/// A device that reloads mid-game loses the client and everything in it.
/// The log has every move it made (log.dart), and a device back at the
/// table reads the log from its start; but the secret its keys were made
/// from was only ever this device's, and a seat that comes back with
/// another cannot open its own cards. So the client keeps each hand's
/// secret here as it draws it, and the device keeps the journal
/// (app: net/seat_store.dart), on the device and nowhere else.
library;

import 'dart:convert';
import 'dart:typed_data';

class TableJournal {
  TableJournal({Map<int, Uint8List>? secrets}) : _secrets = secrets ?? {};

  final Map<int, Uint8List> _secrets;

  /// Called as a hand's secret is kept, for whoever keeps the journal to
  /// write it then.
  void Function(int hand, Uint8List secret)? onKept;

  /// The secret this device's keys for [hand] were made from, if it made
  /// any.
  Uint8List? secretFor(int hand) => _secrets[hand];

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
        'secrets': {for (final e in _secrets.entries) '${e.key}': base64.encode(e.value)},
      };

  /// As [toJson] wrote it, or null for anything else.
  static TableJournal? parse(Object? json) {
    try {
      final m = json as Map;
      return TableJournal(secrets: {
        for (final e in (m['secrets'] as Map).entries) int.parse(e.key as String): Uint8List.fromList(base64.decode(e.value as String)),
      });
    } catch (_) {
      return null;
    }
  }
}
