/// What the app may be told without a new build (docs/06-service.md,
/// "Remote config"): whether live play is open to anyone at all,
/// whether the paid tier is offered, which relays the tables meet on, a
/// line across the front door, that this build is too old, and the
/// clocks of the tables this device starts.
///
/// Read the way the licence is (entitlement.dart): what the device kept
/// last time, before the first frame, and the service asked behind it.
/// Nothing waits on the service. A device that has never reached it, or
/// cannot now, has the config it last had, and one that never had any
/// has none — which is the app as the build made it, every door open
/// and nothing said. The worker checks every field before it serves the
/// row (service/functions/worker.mjs, configOf), and this checks them
/// again: a config is only ever able to narrow what the build does, or
/// say something, and a bad one is never worse than none.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart' show TableTiming;

import 'licence.dart' show handlerAt;
import 'turn_fetch_io.dart' if (dart.library.js_interop) 'turn_fetch_web.dart' as http;

/// A sentence the operator wrote, in the languages they wrote it in.
/// English is always one of them.
class Saying {
  const Saying(this.byLanguage);

  final Map<String, String> byLanguage;

  /// In [language] where it was written in it, else in English.
  String inLanguage(String language) => byLanguage[language] ?? byLanguage['en']!;

  static Saying? parse(Object? json) {
    if (json is! Map) return null;
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || !RegExp(r'^[a-z]{2}$').hasMatch(key) || value is! String) continue;
      final text = value.trim();
      if (text.isNotEmpty && text.length <= 280) out[key] = text;
    }
    return out.containsKey('en') ? Saying(out) : null;
  }
}

/// A line across the front door.
class Notice {
  const Notice({required this.id, required this.text, this.warning = false});

  /// Which banner this is, so a new one is news and an old one is not.
  final String id;
  final Saying text;

  /// Said in the colour of something wrong: an outage, not a notice.
  final bool warning;
}

class RemoteConfig {
  const RemoteConfig({this.live = true, this.offer = true, this.relays, this.banner, this.updateBefore, this.updateText, this.feedback, this.table = TableTiming.standard});

  /// No config at all: the build as it was made.
  static const none = RemoteConfig();

  /// The kill switch: false shuts the doors to live play — the buttons,
  /// a link to a table, and this device's turn as a juror — for every
  /// device that reads it. A game already at a table plays on.
  final bool live;

  /// Whether the paid tier is offered to a device that has not bought
  /// it. False hides what it costs and the way to buy it; a device that
  /// holds a licence keeps its live play.
  final bool offer;

  /// The relays the tables meet on, in place of the build's; null for
  /// the build's own. Read at the app's start (net/relays.dart), so
  /// every device that started after a change meets on the new ones.
  final List<Uri>? relays;

  final Notice? banner;

  /// A build published before this day ("2026-10-01") is asked to
  /// update; null when none is.
  final String? updateBefore;

  /// What it is told, when the operator wrote something; the app's own
  /// words otherwise.
  final Saying? updateText;

  /// Where "Tell us what's broken" goes (feedback_page.dart): an https
  /// page or a mailto address; null for the project's issues.
  final Uri? feedback;

  /// The clocks of a table this device starts — a person's grace and
  /// bank, a held bot seat's deadlines, the waits on a jury — carried
  /// in the start event, so every seat plays by the starter's
  /// (packages/table, timing.dart). A table someone else starts keeps
  /// theirs.
  final TableTiming table;

  /// Whether [published] — this build's day, or "dev" — is a build the
  /// operator asks to be updated. A local build has no day and never is.
  bool updateDue(String published) {
    final before = updateBefore;
    if (before == null || !_day.hasMatch(published)) return false;
    return published.compareTo(before) < 0;
  }

  static final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// The config as the worker serves it, every field checked again: one
  /// that does not check out is left as the build has it.
  static RemoteConfig parse(Object? json) {
    if (json is! Map) return none;
    List<Uri>? relays;
    final r = json['relays'];
    if (r is List && r.isNotEmpty && r.length <= 8) {
      final parsed = [for (final e in r) if (e is String) Uri.tryParse(e)];
      if (parsed.length == r.length && parsed.every((u) => u != null && u.scheme == 'wss' && u.host.isNotEmpty && u.userInfo.isEmpty)) {
        relays = [for (final u in parsed) u!];
      }
    }
    Notice? banner;
    final b = json['banner'];
    if (b is Map) {
      final text = Saying.parse(b['text']);
      final id = b['id'];
      if (text != null && id is String && RegExp(r'^[\w.-]{1,64}$').hasMatch(id)) {
        banner = Notice(id: id, text: text, warning: b['level'] == 'warn');
      }
    }
    final f = json['feedback'];
    final feedback = f is String ? Uri.tryParse(f) : null;
    final u = json['update'];
    final before = u is Map ? u['before'] : null;
    final due = before is String && _day.hasMatch(before);
    return RemoteConfig(
      live: json['live'] is bool ? json['live'] as bool : true,
      offer: json['offer'] is bool ? json['offer'] as bool : true,
      relays: relays,
      banner: banner,
      updateBefore: due ? before : null,
      updateText: due ? Saying.parse((u as Map)['text']) : null,
      feedback: feedback != null && _goesSomewhere(feedback) ? feedback : null,
      table: TableTiming.parse(json['table']),
    );
  }

  /// An address a report may be sent to: a page over https, or mail.
  static bool _goesSomewhere(Uri u) {
    if (u.scheme == 'https') return u.host.isNotEmpty && u.userInfo.isEmpty;
    return u.scheme == 'mailto' && RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(u.path);
  }
}

/// How the config is fetched: one GET. Settable, like [handlerAt] — a
/// widget test cannot reach a socket, so it stands its own here.
Future<String?> Function(Uri url) fetchConfig = http.getText;

/// The config this device goes by, kept on the device between starts.
class RemoteSettings extends ChangeNotifier {
  /// One, like the licence: there is one device, and one operator.
  /// Settable, so a test can give the app a config of its own.
  static RemoteSettings current = RemoteSettings();

  static const _stored = 'remote_config';

  RemoteConfig _config = RemoteConfig.none;
  RemoteConfig get config => _config;

  /// The config the device kept, before the first frame. Nothing here
  /// touches the network.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final kept = prefs.getString(_stored);
    if (kept == null) return;
    try {
      _set(RemoteConfig.parse(jsonDecode(kept)));
    } catch (_) {
      // A row this build cannot read is none.
    }
  }

  /// The service's config, kept for next time. One that cannot be had —
  /// no service behind this build, offline, slow, nonsense — changes
  /// nothing: the device goes on with what it has.
  Future<void> refresh({Uri? endpoint, Duration timeout = const Duration(seconds: 8)}) async {
    final url = endpoint ?? handlerAt('config');
    if (url == null) return;
    String? body;
    try {
      body = await fetchConfig(url).timeout(timeout);
    } catch (_) {
      return;
    }
    if (body == null) return;
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return;
    }
    if (json is! Map) return;
    await (await SharedPreferences.getInstance()).setString(_stored, body);
    _set(RemoteConfig.parse(json));
  }

  /// A config handed over whole, for a test.
  @visibleForTesting
  void adopt(RemoteConfig config) => _set(config);

  void _set(RemoteConfig config) {
    _config = config;
    notifyListeners();
  }
}
