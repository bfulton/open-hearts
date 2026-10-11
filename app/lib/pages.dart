/// The app's pages that have an address of their own (router.dart).
///
/// Each is a place in the browser's history: opening one puts
/// `/subscription` (say) in the address, and an address that names
/// one opens it, on top of the home screen. The back button coming back
/// from Stripe, Stripe's own link home, a refresh, and a link someone
/// sent all land on the page they name, not the front door.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

enum AppPage {
  subscription,
  activate,
  profile,
  about,
  feedback;

  /// As the address names it, under the home screen.
  String get path => '/$name';
}

/// Opens [page] over the current one, with [extra] for what an address
/// cannot carry; resolves to what it was closed with.
Future<T?> openPage<T>(BuildContext context, AppPage page, {Object? extra}) => context.push<T>(located(page.path), extra: extra);

/// The query parameters that belong to the session rather than to a
/// page — `lang`, and the suites' `e2e`, `seed`, `roomWait`, `relay`,
/// `pace`, `target` and `updatecheck` — as the app was opened with them
/// (router.dart sets this).
Map<String, String> session = const {};

/// [path] as an address: with the session's parameters, so a refresh
/// anywhere is the same session. Every way to a page goes through here;
/// a redirect could add them too, but a redirect drops what a push hands
/// its page in memory — a game's.
String located(String path, [Map<String, String> query = const {}]) {
  final all = {...session, ...query};
  return Uri(path: path, queryParameters: all.isEmpty ? null : all).toString();
}

/// A room's address (the home screen, in that room).
String roomPath(String code) => '/room/$code';

/// The games' addresses while they are played. A game lives in memory:
/// these name it while it is played, and an address alone (a refresh,
/// history) goes home.
const soloPath = '/solo';
const livePath = '/live';

/// A finished live game, by its table's id: kept, and looked at by
/// anyone with the address (review_page.dart).
String tablePath(String id) => '/table/$id';
