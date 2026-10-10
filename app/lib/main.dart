import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:table/table.dart' show licenceService, relayCredentials, relayTurnedAway;

import 'crypto/deal.dart';
import 'crypto/schnorr.dart';
import 'entitlement.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/account_profile.dart';
import 'net/address.dart' show paceIn;
import 'net/duty.dart';
import 'net/in_use.dart';
import 'net/licence.dart' show serviceKey;
import 'net/remote_config.dart';
import 'router.dart';
import 'table_model.dart' show tableBeats;
import 'net/report_error.dart';
import 'net/store_buying.dart';
import 'theme.dart';
import 'ui/in_use_screen.dart';
import 'ui/selection.dart';
import 'ui/touch_probe.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // What goes wrong is told, not only printed (net/report_error.dart).
  reportErrors();
  // Addresses are paths, `/subscription`, not `/#/subscription`: the
  // site's worker answers every address of play.openhearts.game (and of
  // /play/ on a preview) with the app (service/functions/worker.mjs),
  // and the router reads the rest.
  usePathUrlStrategy();
  // The end-to-end suite drives the app through its accessibility
  // tree, which the web build only grows on request.
  if (Uri.base.queryParameters.containsKey('e2e')) {
    SemanticsBinding.instance.ensureSemantics();
  }
  // And may ask for its tables' beats shorter (net/address.dart).
  tableBeats = paceIn(Uri.base);
  await installFastSchnorr();
  await loadDeal();
  // The service whose word makes a seat an account's, at every table
  // this device sits at, serves or looks at (packages/table,
  // licence.dart); and what this device shows a relay that asks who it
  // is, and hears when one turns it away for another device of its
  // account (net/in_use.dart).
  licenceService = serviceKey;
  relayCredentials = InUse.current.credentials;
  relayTurnedAway = InUse.current.turnedAway;
  Entitlement.current.addListener(InUse.current.licenceChanged);
  // What this device may do, before the front door is drawn: read off
  // the device, so a device that cannot reach us answers anyway, and
  // asked of the service behind the first frame (docs/06-service.md) —
  // and asked again, a little further apart each time, until the
  // service answers: a start on a slow network is not a start without
  // a subscription.
  final signer = await Identity.signer();
  await Entitlement.current.load(signer.publicKey);
  // And who this device is, which is its account's (net/account_profile.dart):
  // read behind the licence, and again whenever this device becomes
  // the one in use or comes into another account.
  AccountProfile.current.watch();
  unawaited(Entitlement.current.keepAsking(signer).whenComplete(AccountProfile.current.sync));
  // In a store build, the store: what the product costs, and anything
  // it is holding for this app — a renewal, or a purchase the service
  // did not take last time — handed over as soon as it is listened for
  // (net/store_buying.dart). Nothing on the web.
  unawaited(StoreShop.current.open(signer));
  // What the operator last said (net/remote_config.dart): kept from the
  // last start before the first frame, so the relays this start meets
  // on are settled before anything connects, and asked again behind it
  // and every quarter of an hour after (or as `waits.configEvery`
  // says), so a door shut reaches a tab left open all evening.
  await RemoteSettings.current.load();
  unawaited(RemoteSettings.current.refresh());
  _askAgain();
  appLanguage.value = await chosenLanguage();
  runApp(const OpenHeartsApp());
}

/// Asks for the config again after as long as it last said to wait.
void _askAgain() => Timer(waits.configEvery, () {
  // A change to the profile that could not be sent goes now, if it can.
  unawaited(AccountProfile.current.retry());
  unawaited(RemoteSettings.current.refresh().whenComplete(_askAgain));
});

/// The app, and the one thing the app as a whole has to say for
/// itself: whether it is here.
///
/// A device that closes its tab or goes into the background is no use
/// as a juror, and a table that has drawn it should not have to wait
/// out a missed heartbeat to find that out — five seconds in which a
/// hand's escrow rests on somebody who is gone
/// (docs/04-live-play.md). So say it, and say it again
/// on the way back. Best effort by its nature: a crash, a killed tab
/// or a dead link says nothing at all, which is why silence is still
/// timed out.
class OpenHeartsApp extends StatefulWidget {
  const OpenHeartsApp({super.key});

  @override
  State<OpenHeartsApp> createState() => _OpenHeartsAppState();
}

class _OpenHeartsAppState extends State<OpenHeartsApp> {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      switch (state) {
        case AppLifecycleState.resumed:
          Duty.back();
          // Back from the background, perhaps after a long sleep: still
          // the device in use, or not; and its licence asked for now, if
          // the service has not answered yet.
          unawaited(InUse.current.renew());
          Entitlement.current.askAgain();
          unawaited(AccountProfile.current.retry());
        // Hidden is a tab switched away from or a phone's home button:
        // timers throttle, sockets may go, and this device is not
        // answering a summons until it is back. Detached is the page
        // unloading, which is the case worth having most.
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
        case AppLifecycleState.paused:
        case AppLifecycleState.detached:
          Duty.leaving();
      }
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Where everything is (router.dart): made once, for the life of the
  /// app, so its history is the app's.
  late final GoRouter _router = appRouter();

  @override
  Widget build(BuildContext context) {
    // Redrawn in another language the moment one is chosen (l10n.dart).
    return ValueListenableBuilder<Locale?>(
      valueListenable: appLanguage,
      builder: (context, language, _) => MaterialApp.router(
        title: 'Open Hearts',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // The device's language where the app speaks it, English where it
        // does not, unless one was chosen: `?lang=` in the address, a
        // language link on the site, or the About page, each kept for
        // next time.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: language,
        // Any words on any screen can be selected and copied: a name, a
        // rule, an error to send us.
        builder: (context, child) => TouchProbe(child: CopyableSelection(child: InUseScreen(child: child ?? const SizedBox()))),
        routerConfig: _router,
      ),
    );
  }
}
