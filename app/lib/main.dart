import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'crypto/deal.dart';
import 'crypto/schnorr.dart';
import 'entitlement.dart';
import 'home_page.dart';
import 'identity.dart';
import 'net/buying.dart';
import 'net/household.dart';
import 'net/room.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  runApp(const OpenHeartsApp());
}

class OpenHeartsApp extends StatelessWidget {
  const OpenHeartsApp({super.key});

  @override
  Widget build(BuildContext context) {
    // What the address is asking for, read here rather than by the page
    // it is asking: a room shared by a link, a code another device
    // showed, a checkout coming back.
    final room = Uri.base.queryParameters['room']?.trim().toUpperCase();
    return MaterialApp(
      title: 'Open Hearts',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomePage(
        openRoom: room != null && Room.validCode(room) ? room : null,
        openClaim: claimInAddress(),
        justBought: boughtJustNow(),
      ),
    );
  }
}
