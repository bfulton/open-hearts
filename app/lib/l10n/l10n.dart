/// The app's words, in the language the device asks for.
///
/// Every sentence the app shows or speaks is a message in
/// lib/l10n/app_en.arb, translated beside it (app_es.arb and the rest),
/// and flutter generates [AppLocalizations] from them (l10n.yaml). What
/// is here is the little the generated class does not do: the way a
/// widget reaches it, and the words for the engine's own values — a
/// card, a suit, a way to pass — which the engine keeps in English for
/// its logs and its tests and never shows anyone.
library;

import 'package:engine/engine.dart';
import 'package:flutter/widgets.dart';
import 'package:table/table.dart' show Pace;

import 'app_localizations.dart';

export 'app_localizations.dart';

/// English, for whatever has no [BuildContext] to ask — a controller
/// before its page has told it the language — and for a widget drawn
/// outside the app's own [WidgetsApp], as a widget test draws one.
final AppLocalizations english = lookupAppLocalizations(const Locale('en'));

extension Words on BuildContext {
  /// The words for this part of the screen: the app's language, or
  /// [english] where no app above has said which.
  AppLocalizations get l10n => Localizations.of<AppLocalizations>(this, AppLocalizations) ?? english;
}

extension EngineWords on AppLocalizations {
  /// "queen of spades", on the card itself.
  String card(Card c) => cardName(c.rank.name, c.rank.label, c.suit.name);

  /// "the queen of spades", in a sentence.
  String cardInSentence(Card c) => cardWithArticle(c.rank.name, c.rank.label, c.suit.name);

  /// "Pass left", and "No pass" on the fourth hand.
  String pass(PassDirection d) => passDirection(d.name);

  /// The players who share a win, as one phrase: "Anna and Bao".
  String together(Iterable<String> names) => names.join(' $listAnd ');

  /// How fast a player plays, as the profile says it: the same bands as
  /// [Pace.word], whose English this replaces on the screen.
  String paceLine(Pace pace) => pace.known
      ? paceKnown(
          switch (pace.stated) {
            0 => 'unknown',
            <= 4 => 'brisk',
            <= 9 => 'steady',
            <= 20 => 'unhurried',
            _ => 'slow',
          },
          pace.stated)
      : paceUnknown;
}

/// A yes or no as a message's select takes it.
String flag(bool b) => b ? 'true' : 'false';

/// The language the address asks for with `?lang=`, if the app speaks
/// it; null leaves the choice to the device.
Locale? languageInAddress([Uri? at]) {
  final asked = (at ?? Uri.base).queryParameters['lang']?.toLowerCase();
  if (asked == null) return null;
  for (final l in AppLocalizations.supportedLocales) {
    if (l.languageCode == asked) return l;
  }
  return null;
}
