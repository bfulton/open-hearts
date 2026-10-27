/// The app in every language it speaks.
///
/// Two halves. The words: every translation carries the same blanks as
/// the English it translates, every card and every rule has a name of
/// its own in every language, and the English is pinned — the suites
/// in e2e/ read the table by those words. And the screens: every page
/// the app has, in every language, on a small phone and a large one,
/// with nothing running off the edge and nothing cut short. German
/// runs long and French is not far behind, and the place that finds
/// out is here rather than a player's screen.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/about_page.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/feedback_page.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/home_page.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/net/sign_in.dart' show Provider;
import 'package:open_hearts/net/store_buying.dart';
import 'package:open_hearts/options_sheet.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/stats.dart';
import 'package:open_hearts/subscribe_page.dart';
import 'package:open_hearts/table_page.dart';
import 'package:open_hearts/theme.dart';
import 'package:open_hearts/ui/table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart' show Pace, Tally;

import 'home_page_test.dart' show licenceThisDevice;
import 'sign_in_test.dart' show offering;
import 'store_buying_test.dart' show FakeStore, paid, shopWith;

const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// The smallest phone anyone still plays on, and an ordinary one.
const _sizes = {'small': Size(320, 568), 'phone': Size(390, 844)};

final _locales = AppLocalizations.supportedLocales;

/// [home] as the app shows it in [locale]: the same delegates and the
/// same stillness as main.dart and the other suites.
Widget _inLanguage(Locale locale, Widget home) => MaterialApp(
      theme: buildTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(data: const MediaQueryData(disableAnimations: true), child: home),
    );

void _size(WidgetTester tester, Size size) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Every line of text on the screen that was cut short — an ellipsis,
/// or lines beyond its last — as "text (where)". A RenderFlex that
/// overflows fails the test by itself; a Text told to stop at one line
/// does not, and a sentence that ends in "…" is as lost as one that
/// runs off the side. Offstage copies of a badge, laid out only to
/// size the one drawn, are not on the screen and do not count.
List<String> _cut(WidgetTester tester, String where, {Iterable<String> names = const []}) {
  final cut = <String>[];
  for (final element in find.byType(RichText).evaluate()) {
    var ghost = false;
    element.visitAncestorElements((a) {
      ghost = a.widget is BadgeGhost || a.widget is Offstage && (a.widget as Offstage).offstage;
      return !ghost;
    });
    if (ghost) continue;
    final paragraph = element.renderObject! as RenderParagraph;
    final text = paragraph.text.toPlainText();
    // A player's name is theirs, not a translation, and a badge gives a
    // long one way on purpose (ui/table_view.dart).
    if (names.contains(text)) continue;
    if (paragraph.didExceedMaxLines) cut.add('"$text" ($where)');
  }
  return cut;
}

/// The ARB files, by locale: what the translators work in.
Map<String, Map<String, Object?>> _arbs() => {
      for (final f in Directory('lib/l10n').listSync().whereType<File>().where((f) => f.path.endsWith('.arb')))
        RegExp(r'app_(\w+)\.arb$').firstMatch(f.path)!.group(1)!: jsonDecode(f.readAsStringSync()) as Map<String, Object?>,
    };

/// Where the flutter tool running this test lives, when it has not said:
/// two up from the dart it runs on (bin/cache/dart-sdk/bin/dart).
String _flutterRoot() => File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;

void main() {
  group('the words', () {
    test('every translation has every message, with the blanks the English has', () {
      final arbs = _arbs();
      expect(arbs.keys.toSet(), {for (final l in _locales) l.languageCode}, reason: 'an .arb for each language the app says it speaks');
      final english = arbs['en']!;
      final keys = english.keys.where((k) => !k.startsWith('@')).toSet();
      for (final MapEntry(key: locale, value: arb) in arbs.entries) {
        expect(arb.keys.where((k) => !k.startsWith('@')).toSet(), keys, reason: '$locale: the same messages as the English');
        for (final key in keys) {
          final blanks = ((english['@$key'] as Map)['placeholders'] as Map?)?.keys ?? const [];
          for (final blank in blanks) {
            expect(arb[key], matches(RegExp('\\{$blank[},]')), reason: '$locale $key: says {$blank} somewhere');
          }
        }
      }
    });

    test('the English is the words the e2e suites read the table by', () {
      for (final card in engine.Card.deck) {
        expect(english.card(card), card.spoken, reason: 'what a screen reader, and the suites, call a card');
        expect(english.cardInSentence(card), 'the ${card.spoken}');
      }
      for (final d in engine.PassDirection.values) {
        expect(english.pass(d), d.label);
      }
      expect(english.paceLine(const Pace(secondsPerCard: 1, cards: 30)),
          'You play at a brisk pace, about 1 second a card, and are seated with players at a similar pace');
      expect(english.paceLine(const Pace(secondsPerCard: 12, cards: 30)),
          'You play at a unhurried pace, about 12 seconds a card, and are seated with players at a similar pace');
      expect(english.stillOut(0, 'true'), 'No hearts and the queen still out');
      expect(english.stillOut(1, 'false'), '1 heart still out');
      expect(english.stillOut(13, 'true'), '13 hearts and the queen still out');
      expect(english.waitedLine(4, 0), '4 s — bots fill any seat still empty at ten');
      expect(english.waitedLine(4, 1), '4 s, 1 other waiting — bots fill any seat still empty at ten');
      expect(english.onlineCount(0), '0 online');
      expect(english.onlineCount(5), '5 online');
      expect(english.playLiveSpoken(0), 'Play live, nobody else online');
      expect(english.playLiveSpoken(1), 'Play live, 1 online');
      expect(english.playLiveSpoken(7), 'Play live, 7 online');
      expect(english.together(['Ada', 'Bao', 'Cy']), 'Ada and Bao and Cy');
    });

    for (final locale in _locales) {
      test('${locale.languageCode}: every card, suit, rule and way to pass has a name of its own', () {
        final words = lookupAppLocalizations(locale);
        expect({for (final c in engine.Card.deck) words.card(c)}, hasLength(52));
        expect({for (final c in engine.Card.deck) words.cardInSentence(c)}, hasLength(52));
        expect({for (final s in engine.Suit.values) words.refuseFollowSuit(s.name)}, hasLength(4));
        expect({for (final d in engine.PassDirection.values) words.pass(d)}, hasLength(4));
        const named = [
          'noSubscription', 'accountFull', 'notACode', 'noSuchCode', 'codeUsed', 'codeRunOut', 'notADevice', //
          'onAnotherSubscription', 'clockOff', 'other',
        ];
        expect({for (final r in named) words.serviceRefusal(r)}, hasLength(named.length));
        expect({for (final p in [1, 6, 15, 40]) words.paceLine(Pace(secondsPerCard: p.toDouble(), cards: 30))}, hasLength(4));
        expect(words.paceLine(Pace.fresh), words.paceUnknown);
        // Nothing of the message's own machinery left in what is said.
        for (final said in [
          words.cardInSentence(engine.Card.parse('QS')),
          words.stillOut(3, 'true'),
          words.waitedLine(12, 2),
          words.onlineCount(5),
          words.gameLine(50, 'rated'),
          words.hereCount(3, 4, 'unrated'),
        ]) {
          expect(said, isNot(matches(RegExp(r'[{}]'))), reason: said);
        }
      });
    }

    test('the address can ask for a language the app speaks, and only one it speaks', () {
      expect(languageInAddress(Uri.parse('https://x/play/?lang=de')), const Locale('de'));
      expect(languageInAddress(Uri.parse('https://x/play/?lang=PT')), const Locale('pt'));
      expect(languageInAddress(Uri.parse('https://x/play/?lang=ja')), isNull);
      expect(languageInAddress(Uri.parse('https://x/play/')), isNull);
    });

    test('the phones offer exactly the languages the app speaks, in their per-app setting', () {
      final spoken = AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
      final android = File('android/app/src/main/res/xml/locales_config.xml').readAsStringSync();
      expect(RegExp(r'android:name="([\w-]+)"').allMatches(android).map((m) => m.group(1)).toSet(), spoken);
      final ios = File('ios/Runner/Info.plist').readAsStringSync();
      final list = RegExp(r'<key>CFBundleLocalizations</key>\s*<array>([\s\S]*?)</array>').firstMatch(ios)!.group(1)!;
      expect(RegExp(r'<string>([\w-]+)</string>').allMatches(list).map((m) => m.group(1)).toSet(), spoken);
      expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(), contains('android:localeConfig="@xml/locales_config"'));
    });

    test('a chosen language is kept: the address\'s for next time, or the site\'s', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await chosenLanguage(Uri.parse('https://x/play/')), isNull);
      expect(await chosenLanguage(Uri.parse('https://x/play/?lang=fr')), const Locale('fr'));
      expect(await chosenLanguage(Uri.parse('https://x/play/')), const Locale('fr'));
      // What site/public/lang.js keeps when a language link is followed.
      SharedPreferences.setMockInitialValues({chosenLanguageKey: 'es'});
      expect(await chosenLanguage(Uri.parse('https://x/play/')), const Locale('es'));
      SharedPreferences.setMockInitialValues({chosenLanguageKey: 'ja'});
      expect(await chosenLanguage(Uri.parse('https://x/play/')), isNull);
    });
  });

  group('the screens', () {
    // Measured in the font the screen is drawn in. The test font is a
    // square a letter, twice the width of most of them, and it would
    // have every German sentence running off the side of a phone it
    // fits on; Roboto is the material type the web build and Android
    // draw in, and the flutter tool carries it.
    setUpAll(() async {
      final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? _flutterRoot()}/bin/cache/artifacts/material_fonts';
      final roboto = FontLoader('Roboto');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        roboto.addFont(File('$fonts/Roboto-$weight.ttf').readAsBytes().then((b) => ByteData.sublistView(b)));
      }
      await roboto.load();
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({'identity_name': 'Ada'});
      Entitlement.current = Entitlement(service: _service);
    });
    tearDown(() {
      Entitlement.current = Entitlement();
      RemoteSettings.current = RemoteSettings();
    });

    for (final locale in _locales) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        final lang = locale.languageCode;

        testWidgets('$lang, $name: the front door, locked and open', (tester) async {
          _size(tester, size);
          await Entitlement.current.load((await Identity.signer()).publicKey);
          await tester.pumpWidget(_inLanguage(locale, const HomePage(online: false)));
          await tester.pumpAndSettle();
          final cut = _cut(tester, 'locked');
          expect(find.text(lookupAppLocalizations(locale).playSolo), findsOneWidget, reason: 'in $lang');

          await licenceThisDevice();
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'open'));
          expect(find.text(lookupAppLocalizations(locale).playFriends), findsOneWidget);

          // Paused by the operator, with a notice across the top.
          RemoteSettings.current.adopt(RemoteConfig.parse({
            'live': false,
            'banner': {'id': 'b', 'text': {'en': 'The relays are down until six this evening, UTC.'}},
          }));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'paused'));
          expect(find.text(lookupAppLocalizations(locale).livePaused), findsOneWidget);
          RemoteSettings.current.adopt(RemoteConfig.parse({'update': {'before': '2026-10-01'}}));
          await tester.pumpWidget(_inLanguage(locale, const Scaffold(body: OperatorNotes(published: '2026-09-01'))));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'please update'));
          expect(find.text(lookupAppLocalizations(locale).updateDueApp), findsOneWidget);
          expect(cut, isEmpty);
        });

        testWidgets('$lang, $name: a solo game, from the pass to the end of the game', (tester) async {
          _size(tester, size);
          await tester.pumpWidget(_inLanguage(locale, const TablePage(seed: 4, paced: false)));
          await tester.pumpAndSettle();
          final controller = tester.widget<TableView>(find.byType(TableView)).controller;
          List<String> cutHere(String where) => _cut(tester, where, names: controller.names);
          final cut = cutHere('passing');
          var handOver = false;
          // Played by the controller rather than the thumb: what is
          // under test is every screen the game passes through, and
          // that is the same however the cards are chosen.
          for (var steps = 0; steps < 2000 && controller.game.phase != engine.Phase.gameOver; steps++) {
            if (controller.awaitingPass) {
              for (final c in controller.game.handOf(controller.mySeat).take(engine.passSize - controller.selected.length)) {
                controller.toggleSelected(c);
              }
              await tester.pump();
              cut.addAll(cutHere('ready to pass'));
              controller.confirmPass();
            } else if (controller.awaitingPlay) {
              controller.playCard(controller.legalNow.first);
            }
            await tester.pumpAndSettle();
            if (steps == 6) cut.addAll(cutHere('playing'));
            if (controller.game.phase == engine.Phase.handOver) {
              if (!handOver) cut.addAll(cutHere('hand over'));
              handOver = true;
              await tester.tap(find.text(lookupAppLocalizations(locale).nextHand));
              await tester.pumpAndSettle();
            }
          }
          expect(controller.game.phase, engine.Phase.gameOver);
          expect(handOver, isTrue);
          cut.addAll(cutHere('game over'));
          expect(cut, isEmpty);
        });

        testWidgets('$lang, $name: what a live table says under the felt fits the line it has', (tester) async {
          _size(tester, size);
          // The live page's notes (live/live_page.dart), in the strip
          // between the felt and the hand: two lines at most, whatever
          // the language, and a sentence that needs more is cut short
          // there. A relay's refusal carries forty characters of the
          // relay's own and is two lines in English already; in another
          // language it may need no more than it does in English.
          List<String> notes(AppLocalizations words) => [
            words.noRelayTakesEvents('blocked: rate-limited, slow down a…'),
            words.waitingToReconnect,
            words.openingDepartedHand,
            words.dealingKeys,
            words.shuffling(3),
            words.dealingTheCards,
            words.openingTheCards,
          ];
          Future<double> needs(String note) async {
            // As ActionBar holds a note: the width of the screen, centred,
            // two lines at most (table_page.dart).
            await tester.pumpWidget(_inLanguage(
                locale,
                Scaffold(
                    body: Align(
                        alignment: Alignment.bottomCenter,
                        child: Center(
                            child: Text(note, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Palette.chromeDim)))))));
            final paragraph = tester.renderObject<RenderParagraph>(find.text(note));
            return paragraph.getMinIntrinsicHeight(paragraph.size.width);
          }

          final tall = <String>[];
          final theirs = notes(lookupAppLocalizations(locale));
          final ours = notes(english);
          final twoLines = await needs('M\nM');
          for (var i = 0; i < theirs.length; i++) {
            final room = max(twoLines, await needs(ours[i]));
            final needed = await needs(theirs[i]);
            if (needed > room) tall.add('"${theirs[i]}" needs ${needed.toStringAsFixed(1)} px of $room');
          }
          expect(tall, isEmpty);
        });

        testWidgets('$lang, $name: the profile, the options, About, and Live play', (tester) async {
          _size(tester, size);
          final cut = <String>[];
          final stats = Stream.value(const PlayerStats(
            ratedGames: 3,
            reached: true,
            live: Tally(games: 3, won: 1, points: 210, best: 40),
            alone: Tally(games: 12, won: 4, points: 800, best: 22),
            pace: Pace(secondsPerCard: 6, cards: 40),
            history: SoloHistory(
                recent: [62, 41, 88, 30, 57, 44, 73, 25, 66, 52, 39, 91, 48, 35, 70, 55, 61, 28, 47, 59],
                hands: 113,
                queens: 21,
                moonsShot: 2,
                moonsBlocked: 5),
          ));
          await tester.pumpWidget(_inLanguage(
              locale, ProfilePage(current: (name: 'Ada', avatar: Avatar.none), seed: 'k1', stats: stats)));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text(lookupAppLocalizations(locale).statsMoonsBlocked), 200, scrollable: find.byType(Scrollable).first);
          cut.addAll(_cut(tester, 'profile'));

          await tester.pumpWidget(_inLanguage(
              locale,
              Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(onPressed: () => showGameOptions(context, current: const GameOptions()), child: const Text('options'))))));
          await tester.tap(find.text('options'));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'options'));

          await tester.pumpWidget(_inLanguage(locale, const AboutPage()));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'about'));

          await tester.pumpWidget(_inLanguage(locale, const FeedbackPage(record: 'oh1:4:Ada,Bao,Cy::')));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'feedback'));

          // With every sign-in offered, which is the most the page says.
          offering([Provider.apple, Provider.google]);
          await Entitlement.current.load((await Identity.signer()).publicKey);
          await tester.pumpWidget(_inLanguage(locale, const SubscribePage()));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'live play, to buy'));

          // A store build's: the store's price and the terms the stores
          // require beside the button, a purchase waiting for approval,
          // and the page of a subscriber who bought it there.
          final words = lookupAppLocalizations(locale);
          final store = FakeStore(kind: name == 'small' ? StoreKind.google : StoreKind.apple, price: r'R$ 32,90');
          await (await SharedPreferences.getInstance()).setBool('store_bought', true);
          await shopWith(store);
          store.says([paid('', status: StoreStatus.pending)]);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(_inLanguage(locale, const SubscribePage()));
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'live play, in a store'));
          expect(find.text(words.storePending), findsOneWidget);
          expect(find.text(words.restorePurchases), findsOneWidget);
          await licenceThisDevice();
          await tester.pumpAndSettle();
          cut.addAll(_cut(tester, 'live play, bought in a store'));
          expect(find.text(words.manageInStore(store.kind.name)), findsOneWidget);
          expect(cut, isEmpty);
        });
      }
    }
  });
}
