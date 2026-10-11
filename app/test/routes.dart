/// A test's app on the real routes (router.dart): the page under test
/// opened by its own address, over a stand-in home screen, so what it
/// opens and closes goes where it goes in the app.
library;

import 'package:flutter/material.dart';
import 'package:open_hearts/router.dart';
import 'package:open_hearts/theme.dart';

Widget routed(String location, {Object? extra, Widget home = const Scaffold(body: Text('home'))}) => MaterialApp.router(
      theme: buildTheme(),
      routerConfig: appRouter(
        boot: Uri.parse('https://play.openhearts.game/'),
        initialLocation: location,
        initialExtra: extra,
        home: (_, _) => home,
      ),
    );
