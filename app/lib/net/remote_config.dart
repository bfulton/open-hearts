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

/// How long this device waits on the service and the relays: the
/// `waits` of the remote config, in milliseconds (minutes for
/// [configEvery]). Each is taken if it is a whole number within its
/// bounds and left at the build's own if not; the bounds keep a typo
/// from making a device give up at once or hang for ever.
@immutable
class AppWaits {
  const AppWaits({
    this.licence = const Duration(seconds: 6),
    this.household = const Duration(seconds: 10),
    this.buy = const Duration(seconds: 12),
    this.turn = const Duration(seconds: 5),
    this.config = const Duration(seconds: 8),
    this.configEvery = const Duration(minutes: 15),
    this.relaySlow = const Duration(seconds: 8),
    this.relayGiveUp = const Duration(seconds: 40),
    this.standing = const Duration(seconds: 8),
    this.standingAll = const Duration(seconds: 4),
    this.roomStart = const Duration(seconds: 10),
    this.meshAnswer = const Duration(seconds: 20),
  });

  /// The build's own, which are what every device waited before.
  static const standard = AppWaits();

  /// Asking the service for this device's licence.
  final Duration licence;

  /// A household's code, claim, drop or list.
  final Duration household;

  /// Opening a checkout.
  final Duration buy;

  /// TURN credentials, before a table goes on with STUN alone.
  final Duration turn;

  /// This config itself.
  final Duration config;

  /// How often an open app asks for this config again.
  final Duration configEvery;

  /// A relay slow to answer: when the screen says so, and when it is
  /// given up on (home_page.dart, waitForRelay).
  final Duration relaySlow;
  final Duration relayGiveUp;

  /// Loading the standings: the first relay, then the rest.
  final Duration standing;
  final Duration standingAll;

  /// A friends' room starts this long after the last arrival, once two
  /// are in.
  final Duration roomStart;

  /// A direct connection to a peer not up by now is left to the relay.
  final Duration meshAnswer;

  /// Least and most, in milliseconds (minutes for configEvery).
  static const bounds = <String, (int, int)>{
    'licenceMs': (2000, 30000),
    'householdMs': (3000, 30000),
    'buyMs': (3000, 60000),
    'turnMs': (2000, 30000),
    'configMs': (2000, 30000),
    'configEveryMin': (5, 240),
    'relaySlowMs': (3000, 30000),
    'relayGiveUpMs': (15000, 180000),
    'standingMs': (3000, 30000),
    'standingAllMs': (1000, 20000),
    'roomStartMs': (3000, 60000),
    'meshAnswerMs': (5000, 60000),
  };

  static AppWaits parse(Object? json) {
    if (json is! Map) return standard;
    Duration take(String name, Duration standard) {
      final v = json[name];
      final (least, most) = bounds[name]!;
      if (v is! int || v < least || v > most) return standard;
      return name.endsWith('Min') ? Duration(minutes: v) : Duration(milliseconds: v);
    }

    const s = standard;
    var slow = take('relaySlowMs', s.relaySlow);
    var giveUp = take('relayGiveUpMs', s.relayGiveUp);
    // Saying it is slow comes before giving up, or it is never said.
    if (slow >= giveUp) (slow, giveUp) = (s.relaySlow, s.relayGiveUp);
    return AppWaits(
      licence: take('licenceMs', s.licence),
      household: take('householdMs', s.household),
      buy: take('buyMs', s.buy),
      turn: take('turnMs', s.turn),
      config: take('configMs', s.config),
      configEvery: take('configEveryMin', s.configEvery),
      relaySlow: slow,
      relayGiveUp: giveUp,
      standing: take('standingMs', s.standing),
      standingAll: take('standingAllMs', s.standingAll),
      roomStart: take('roomStartMs', s.roomStart),
      meshAnswer: take('meshAnswerMs', s.meshAnswer),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppWaits &&
      other.licence == licence &&
      other.household == household &&
      other.buy == buy &&
      other.turn == turn &&
      other.config == config &&
      other.configEvery == configEvery &&
      other.relaySlow == relaySlow &&
      other.relayGiveUp == relayGiveUp &&
      other.standing == standing &&
      other.standingAll == standingAll &&
      other.roomStart == roomStart &&
      other.meshAnswer == meshAnswer;

  @override
  int get hashCode => Object.hash(
    licence,
    household,
    buy,
    turn,
    config,
    configEvery,
    relaySlow,
    relayGiveUp,
    standing,
    standingAll,
    roomStart,
    meshAnswer,
  );
}

/// The waits as the operator last set them.
AppWaits get waits => RemoteSettings.current.config.waits;

class RemoteConfig {
  const RemoteConfig({
    this.live = true,
    this.offer = true,
    this.relays,
    this.banner,
    this.updateBefore,
    this.updateText,
    this.feedback,
    this.privacy,
    this.terms,
    this.price,
    this.table = TableTiming.standard,
    this.waits = AppWaits.standard,
  });

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

  /// Where the privacy policy and the terms of use are, which the
  /// subscription page links to (a store's review asks for both); null
  /// for the site's own (subscribe_page.dart, legalPage).
  final Uri? privacy;
  final Uri? terms;

  /// What a year of live play costs, as shown on the web beside
  /// Subscribe ("\$5.99"), when it is not the build's: changed with the
  /// Stripe price it describes. A store build shows the store's own.
  final String? price;

  /// The clocks of a table this device starts — a person's grace and
  /// bank, a held bot seat's deadlines, the waits on a jury — carried
  /// in the start event, so every seat plays by the starter's
  /// (packages/table, timing.dart). A table someone else starts keeps
  /// theirs.
  final TableTiming table;

  /// How long this device waits on the network before it says so or
  /// gives up: its own patience, not a table's, so each is taken or
  /// left on its own ([AppWaits]).
  final AppWaits waits;

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
      final parsed = [
        for (final e in r)
          if (e is String) Uri.tryParse(e),
      ];
      if (parsed.length == r.length &&
          parsed.every((u) => u != null && u.scheme == 'wss' && u.host.isNotEmpty && u.userInfo.isEmpty)) {
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
      privacy: _page(json['privacy']),
      terms: _page(json['terms']),
      price: _price(json['price']),
      table: TableTiming.parse(json['table']),
      waits: AppWaits.parse(json['waits']),
    );
  }

  /// A short price with a digit in it and nothing that could be markup.
  static String? _price(Object? raw) =>
      raw is String && RegExp(r'^[^\s<>{}]{1,12}$').hasMatch(raw) && RegExp(r'\d').hasMatch(raw) ? raw : null;

  /// A page over https, or nothing.
  static Uri? _page(Object? raw) {
    final u = raw is String ? Uri.tryParse(raw) : null;
    return u != null && u.scheme == 'https' && u.host.isNotEmpty && u.userInfo.isEmpty ? u : null;
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
  Future<void> refresh({Uri? endpoint, Duration? timeout}) async {
    timeout ??= waits.config;
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
