/// Where everything is: one table of addresses, and the pages they open.
///
/// The address is the app's state as far as the browser is concerned, and
/// every way of arriving goes through here — a link, a refresh, the back
/// and forward buttons, Stripe sending the browser home. So there is one
/// place that says what `/subscription` is, rather than each page
/// arranging its own way back.
///
///   /                   the home screen
///   /room/ABCD          the home screen, in room ABCD
///   /subscription …     the pages in pages.dart, over the home screen
///   /solo, /live        a game alone, and a live one. A game lives in
///                       memory, so these are reached only by playing:
///                       an address alone, a refresh or a step through
///                       history, goes home.
///   /table/ID           a finished live game, kept and checked
///                       (review_page.dart)
///
/// A few query parameters are the session's rather than the page's —
/// `lang`, and the suites' `e2e`, `roomWait` and `updatecheck` — and stay
/// in the address wherever it goes (pages.dart, [located]), so a refresh
/// is the same session.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:table/table.dart' show validTableId;

import 'about_page.dart';
import 'activate_page.dart';
import 'feedback_page.dart';
import 'home_page.dart';
import 'live_controller.dart';
import 'live/live_page.dart';
import 'net/buying.dart';
import 'net/household.dart';
import 'net/room.dart';
import 'pages.dart';
import 'profile_page.dart';
import 'review_page.dart';
import 'stats.dart';
import 'subscribe_page.dart';
import 'table_page.dart';

/// The query parameters that belong to the session, not to a page.
const sessionParams = {'lang', 'e2e', 'seed', 'roomWait', 'updatecheck'};

/// The home screen is one page whatever room it is in: the same key, so
/// `/` and `/room/ABCD` are the same screen with the same state, and
/// entering or leaving a room is not a new one.
const _homeKey = ValueKey('home');

/// [boot] is the address the app was opened at, for its session's
/// parameters. A test starts at [initialLocation], and may stand its own
/// screen in for the home screen with [home].
GoRouter appRouter({
  Uri? boot,
  bool online = true,
  String? initialLocation,
  Object? initialExtra,
  Widget Function(GoRouterState state, String? room)? home,
}) {
  session = {
    for (final e in (boot ?? Uri.base).queryParameters.entries)
      if (sessionParams.contains(e.key)) e.key: e.value,
  };
  Page<void> homePage(GoRouterState state, {String? room}) => MaterialPage<void>(
        key: _homeKey,
        child: home?.call(state, room) ??
            HomePage(
              openRoom: room,
              openClaim: claimInAddress(state.uri),
              justBought: boughtJustNow(state.uri),
              online: online,
            ),
      );
  // A page opened over another — About over a live table, Activate over
  // Subscription — is pushed, so the one under it stays as it was; and
  // its address is the browser's. go_router keeps a pushed page out of
  // the address unless asked, for an app whose pushed pages could not be
  // opened by their address alone. Every page here can be, over the home
  // screen, and a game by its address alone goes home (below).
  GoRouter.optionURLReflectsImperativeAPIs = true;
  return GoRouter(
    initialLocation: initialLocation,
    initialExtra: initialExtra,
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => homePage(state),
        routes: [
          GoRoute(path: AppPage.subscription.name, builder: (_, _) => const SubscribePage()),
          GoRoute(path: AppPage.activate.name, builder: (_, _) => const ActivatePage()),
          GoRoute(path: AppPage.about.name, builder: (_, _) => const AboutPage()),
          GoRoute(path: AppPage.feedback.name, builder: (_, state) => FeedbackPage(record: state.extra as String?)),
          GoRoute(path: AppPage.profile.name, builder: (_, state) => ProfilePage(stats: state.extra as Stream<PlayerStats>?)),
          GoRoute(
            path: soloPath.substring(1),
            redirect: (_, state) => state.extra is SoloGame ? null : '/',
            builder: (_, state) {
              final game = state.extra! as SoloGame;
              return TablePage(target: game.target, seed: game.seed, paced: game.paced);
            },
          ),
          GoRoute(
            path: livePath.substring(1),
            redirect: (_, state) => state.extra is LiveController ? null : '/',
            builder: (_, state) => LivePage(controller: state.extra! as LiveController),
          ),
        ],
      ),
      GoRoute(
        path: '/table/:id',
        redirect: (_, state) => validTableId(state.pathParameters['id'] ?? '') ? null : '/',
        builder: (_, state) => ReviewPage(table: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/room/:code',
        redirect: (_, state) => Room.validCode(state.pathParameters['code'] ?? '') ? null : '/',
        pageBuilder: (context, state) => homePage(state, room: state.pathParameters['code']),
      ),
    ],
  );
}

