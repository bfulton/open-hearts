import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'crypto/deal.dart';
import 'crypto/schnorr.dart';
import 'entitlement.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/duty.dart';
import 'net/remote_config.dart';
import 'router.dart';
import 'net/store_buying.dart';
import 'theme.dart';
import 'ui/selection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Addresses are paths, `/play/subscription`, not `/play/#/subscription`:
  // the site answers every address under /play with the app
  // (service/functions/worker.mjs), and the router reads the rest.
  usePathUrlStrategy();
  // The end-to-end suite drives the app through its accessibility
  // tree, which the web build only grows on request.
  if (Uri.base.queryParameters.containsKey('e2e')) {
    SemanticsBinding.instance.ensureSemantics();
  }
  await installFastSchnorr();
  await loadDeal();
  // What this device may do, before the front door is drawn: read off
  // the device, so a device that cannot reach us answers anyway, and
  // asked of the service behind the first frame (docs/06-service.md).
  final signer = await Identity.signer();
  await Entitlement.current.load(signer.publicKey);
  unawaited(Entitlement.current.refresh(signer));
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
  runApp(const OpenHeartsApp());
}

/// Asks for the config again after as long as it last said to wait.
void _askAgain() => Timer(waits.configEvery, () {
  unawaited(RemoteSettings.current.refresh().whenComplete(_askAgain));
});

/// The app, and the one thing the app as a whole has to say for
/// itself: whether it is here.
///
/// A device that closes its tab or goes into the background is no use
/// as a juror, and a table that has drawn it should not have to wait
/// out a missed heartbeat to find that out — five seconds in which a
/// hand's escrow rests on somebody who is gone
/// (docs/04-live-play.md, "The sizing"). So say it, and say it again
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
    return MaterialApp.router(
      title: 'Open Hearts',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // The device's language where the app speaks it, English where it
      // does not; `?lang=` in the address chooses one instead, for a
      // person on a borrowed browser and for the suites (l10n/l10n.dart).
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: languageInAddress(),
      // Any words on any screen can be selected and copied: a name, a
      // rule, an error to send us.
      builder: (context, child) => CopyableSelection(child: child ?? const SizedBox()),
      routerConfig: _router,
    );
  }
}
