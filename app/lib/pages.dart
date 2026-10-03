/// The app's pages that have an address of their own.
///
/// On the web each of these is a place in the browser's history: opening
/// one puts `#/subscription` (say) in the address, and an address that
/// names one opens it, on top of the home screen. So the back button
/// coming back from Stripe, Stripe's own link home, a refresh, and a link
/// someone sent all land on the page they name, not the front door.
///
/// A page is opened from an address by the home screen, with the same
/// call its menu makes (home_page.dart, [HomePage.openAt]): a page that
/// hands something back to the home screen — the profile does — is then
/// opened exactly as it always is. A game is not here: it is a state in
/// memory, and an address cannot bring one back.
library;

import 'package:flutter/material.dart';

enum AppPage {
  subscription,
  activate,
  profile,
  about,
  feedback;

  /// As the address names it.
  String get path => '/$name';

  /// The page an address's route names, or null for the home screen or
  /// one this build does not know.
  static AppPage? at(String? route) {
    if (route == null) return null;
    final name = Uri.tryParse(route)?.path.replaceFirst('/', '') ?? '';
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// [page]'s route, carrying its name to the address.
MaterialPageRoute<T> pageRoute<T>(AppPage page, WidgetBuilder builder) =>
    MaterialPageRoute<T>(builder: builder, settings: RouteSettings(name: page.path));
