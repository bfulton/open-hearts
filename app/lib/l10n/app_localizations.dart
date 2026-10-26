import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('de'),
    Locale('es'),
    Locale('fr'),
    Locale('pt'),
  ];

  /// A card's name, as a screen reader says it on a card in the hand. rank is one of two..ten, jack, queen, king, ace; number is the numeral for two..ten; suit is clubs, diamonds, spades or hearts.
  ///
  /// In en, this message translates to:
  /// **'{rank, select, jack{jack} queen{queen} king{king} ace{ace} other{{number}}} of {suit, select, clubs{clubs} diamonds{diamonds} spades{spades} other{hearts}}'**
  String cardName(String rank, String number, String suit);

  /// A card's name with its article, as it goes in a sentence: 'Anna played {card}'. Use the case the sentences seatLed and seatPlayed need.
  ///
  /// In en, this message translates to:
  /// **'the {rank, select, jack{jack} queen{queen} king{king} ace{ace} other{{number}}} of {suit, select, clubs{clubs} diamonds{diamonds} spades{spades} other{hearts}}'**
  String cardWithArticle(String rank, String number, String suit);

  /// Read by a screen reader for the first card of a trick. card is cardWithArticle.
  ///
  /// In en, this message translates to:
  /// **'{name} led {card}'**
  String seatLed(String name, String card);

  /// Read by a screen reader for every later card of a trick. card is cardWithArticle.
  ///
  /// In en, this message translates to:
  /// **'{name} played {card}'**
  String seatPlayed(String name, String card);

  /// Which way this hand's cards are passed. direction is left, right, across or hold.
  ///
  /// In en, this message translates to:
  /// **'{direction, select, left{Pass left} right{Pass right} across{Pass across} other{No pass}}'**
  String passDirection(String direction);

  /// Said when the player tries to lead anything but the two of clubs to the first trick.
  ///
  /// In en, this message translates to:
  /// **'The 2 of clubs leads the first trick'**
  String get refuseFirstLead;

  /// Said when the player tries to play off-suit while holding the suit that was led.
  ///
  /// In en, this message translates to:
  /// **'{suit, select, clubs{You have to follow clubs} diamonds{You have to follow diamonds} spades{You have to follow spades} other{You have to follow hearts}}'**
  String refuseFollowSuit(String suit);

  /// Said when the player tries to play a heart or the queen of spades on the first trick.
  ///
  /// In en, this message translates to:
  /// **'No points on the first trick'**
  String get refuseFirstTrickPoints;

  /// Said when the player tries to lead a heart before hearts are broken.
  ///
  /// In en, this message translates to:
  /// **'Hearts aren\'t broken yet'**
  String get refuseHeartsUnbroken;

  /// Said when a card cannot be played for any other reason.
  ///
  /// In en, this message translates to:
  /// **'You cannot play that card'**
  String get refuseOther;

  /// The player's own name, wherever the table lists the players.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// A seat whose player's name is not known.
  ///
  /// In en, this message translates to:
  /// **'Seat {seat}'**
  String seatNumber(int seat);

  /// The line along the top of the table: the hand number, which way the cards pass (passDirection), and the score the game is played to.
  ///
  /// In en, this message translates to:
  /// **'Hand {hand}  ·  {pass}  ·  to {target}'**
  String handHeader(int hand, String pass, int target);

  /// handHeader without the score the game is played to, where the reader's text size leaves no room for all of it: the hand number and which way the cards pass, which change from hand to hand.
  ///
  /// In en, this message translates to:
  /// **'Hand {hand}  ·  {pass}'**
  String handHeaderShort(int hand, String pass);

  /// Said by a screen reader about the heart at the top of the table.
  ///
  /// In en, this message translates to:
  /// **'Hearts are broken'**
  String get heartsBroken;

  /// Said by a screen reader about the heart at the top of the table.
  ///
  /// In en, this message translates to:
  /// **'Hearts not broken'**
  String get heartsNotBroken;

  /// Said by a screen reader for the menu button at the top left.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get menu;

  /// Menu item that leaves the game.
  ///
  /// In en, this message translates to:
  /// **'Leave the table'**
  String get leaveTheTable;

  /// Menu item and page title: about the app.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// On the About page, on the web: the language the app is in.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// The language choice that follows the device or browser.
  ///
  /// In en, this message translates to:
  /// **'Same as this device'**
  String get deviceLanguage;

  /// Shown briefly after the game's record is put on the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Record copied'**
  String get recordCopied;

  /// While picking the three cards to pass: how many are still to choose.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Choose 1 more to pass} other{Choose {count} more to pass}}'**
  String choosePass(int count);

  /// choosePass, where the reader's text size leaves no room for the whole of it beside the Pass button: how many more to choose, leaving "to pass" to the button that says it. As short as the language allows.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Choose 1 more} other{Choose {count} more}}'**
  String choosePassShort(int count);

  /// The button that passes the three chosen cards.
  ///
  /// In en, this message translates to:
  /// **'Pass'**
  String get passButton;

  /// Beside the cards the player was passed, during the first trick.
  ///
  /// In en, this message translates to:
  /// **'{name} passed you'**
  String passedYou(String name);

  /// Beside the cards the player passed, while the others choose theirs.
  ///
  /// In en, this message translates to:
  /// **'Passed to {name}'**
  String passedTo(String name);

  /// While the others choose the cards they pass.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the others'**
  String get waitingForOthers;

  /// Read by a screen reader for a player's badge at the table.
  ///
  /// In en, this message translates to:
  /// **'{name}: {total} in the game, {taken} this hand'**
  String seatScores(String name, int total, int taken);

  /// Added to seatScores when it is that player's turn.
  ///
  /// In en, this message translates to:
  /// **', on turn'**
  String get seatOnTurn;

  /// Added after a seat's name where a screen reader says the seat (seatScores), at a live table, when the seat is played by a bot rather than a person.
  ///
  /// In en, this message translates to:
  /// **', a bot'**
  String get seatIsBot;

  /// What the small robot on a bot's icon at a live table says when touched: that the seat is played by a bot, not a person. One short word.
  ///
  /// In en, this message translates to:
  /// **'Bot'**
  String get botTag;

  /// Added to seatScores when that player's clock is running.
  ///
  /// In en, this message translates to:
  /// **', {seconds} s on the clock'**
  String seatClock(int seconds);

  /// On the table when the player wins the trick.
  ///
  /// In en, this message translates to:
  /// **'You take it'**
  String get youTakeIt;

  /// On the table when another player wins the trick.
  ///
  /// In en, this message translates to:
  /// **'{name} takes it'**
  String takesIt(String name);

  /// On the table when it is the player's turn.
  ///
  /// In en, this message translates to:
  /// **'Your turn'**
  String get yourTurn;

  /// Heading of the column beside the table that lists the cards already played this hand.
  ///
  /// In en, this message translates to:
  /// **'What has gone'**
  String get whatHasGone;

  /// Under the cards already played: how many hearts, and whether the queen of spades, have not been played yet. queen is true or false.
  ///
  /// In en, this message translates to:
  /// **'{hearts, plural, =0{No hearts} =1{1 heart} other{{hearts} hearts}}{queen, select, true{ and the queen} other{}} still out'**
  String stillOut(int hearts, String queen);

  /// Button on the sheet after a hand.
  ///
  /// In en, this message translates to:
  /// **'Next hand'**
  String get nextHand;

  /// Button on the sheet after a game.
  ///
  /// In en, this message translates to:
  /// **'New game'**
  String get newGame;

  /// At the end of a live game: another game, begun the way this one was — the same pool, or the same friends' room.
  ///
  /// In en, this message translates to:
  /// **'Play again'**
  String get playAgain;

  /// Title of the sheet after a hand.
  ///
  /// In en, this message translates to:
  /// **'Hand {hand}'**
  String handNumber(int hand);

  /// Title of the sheet after a hand in which the player took every point.
  ///
  /// In en, this message translates to:
  /// **'You shot the moon'**
  String get youShotTheMoon;

  /// Title of the sheet after a hand in which another player took every point.
  ///
  /// In en, this message translates to:
  /// **'{name} shot the moon'**
  String shotTheMoon(String name);

  /// Under shotTheMoon: the 26 points go to everyone else instead.
  ///
  /// In en, this message translates to:
  /// **'All 26 — everyone else takes them'**
  String get shotTheMoonDetail;

  /// Title of the sheet after a game the player won jointly.
  ///
  /// In en, this message translates to:
  /// **'A share of it'**
  String get aShareOfIt;

  /// Title of the sheet after a game the player won.
  ///
  /// In en, this message translates to:
  /// **'You win'**
  String get youWin;

  /// Title of the sheet after a game others won jointly. names is the winners' names joined with listAnd.
  ///
  /// In en, this message translates to:
  /// **'{names} tie'**
  String namesTie(String names);

  /// The word that joins the names of players who tie: 'Anna and Bao'.
  ///
  /// In en, this message translates to:
  /// **'and'**
  String get listAnd;

  /// Title of the sheet after a game another player won.
  ///
  /// In en, this message translates to:
  /// **'{name} wins'**
  String nameWins(String name);

  /// Under the title of the sheet after a game: the lowest score wins.
  ///
  /// In en, this message translates to:
  /// **'{hands, plural, =1{Lowest score after 1 hand} other{Lowest score after {hands} hands}}'**
  String lowestScoreAfter(int hands);

  /// Button on the sheet after a solo game: puts a line of text that replays the game on the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy record'**
  String get copyRecord;

  /// On the sheet after a rated game that did not move the player's rating.
  ///
  /// In en, this message translates to:
  /// **'Rating {rating}'**
  String ratingNow(String rating);

  /// On the sheet after a rated game: the player's rating before and after.
  ///
  /// In en, this message translates to:
  /// **'Rating {before} → {after}'**
  String ratingMoved(String before, String after);

  /// Under the app's name on the front door.
  ///
  /// In en, this message translates to:
  /// **'Open source card game, no ads'**
  String get tagline;

  /// Button: a game against three bots.
  ///
  /// In en, this message translates to:
  /// **'Play solo'**
  String get playSolo;

  /// Shown while the app waits a long time to connect. A relay is a server that passes messages between players.
  ///
  /// In en, this message translates to:
  /// **'Still looking for a relay…'**
  String get stillLookingForRelay;

  /// Shown when every relay refuses this device's messages. reason is the relay's own words, in English.
  ///
  /// In en, this message translates to:
  /// **'No relay will take this device\'s events: {reason}'**
  String noRelayTakesEvents(String reason);

  /// Shown when connecting fails. error is a technical message, in English.
  ///
  /// In en, this message translates to:
  /// **'Could not connect: {error}'**
  String couldNotConnect(String error);

  /// Shown when no relay could be reached at all.
  ///
  /// In en, this message translates to:
  /// **'No relay answered. Check the connection and try again.'**
  String get noRelayAnswered;

  /// Shown when the table a link opened started without a seat for this player.
  ///
  /// In en, this message translates to:
  /// **'That table filled up without you'**
  String get tableFilledWithoutYou;

  /// Shown briefly after a link is put on the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get linkCopied;

  /// Live play with other people: the paid part of the app. A menu item, a heading and a page title.
  ///
  /// In en, this message translates to:
  /// **'Live play'**
  String get livePlay;

  /// The button in the top right corner, and the page it opens: the player's name and picture.
  ///
  /// In en, this message translates to:
  /// **'Your profile'**
  String get yourProfile;

  /// The button that opens the game options, and their sheet's title.
  ///
  /// In en, this message translates to:
  /// **'Game options'**
  String get gameOptions;

  /// The game the player is asking for: the score it ends at, and whether it is rated. rated is rated or unrated.
  ///
  /// In en, this message translates to:
  /// **'{target} points · {rated, select, rated{rated} other{unrated}}'**
  String gameLine(int target, String rated);

  /// Button: a game with whoever else is waiting online.
  ///
  /// In en, this message translates to:
  /// **'Play live'**
  String get playLive;

  /// Read by a screen reader for the Play live button. online is how many other people are online, not counting this device.
  ///
  /// In en, this message translates to:
  /// **'{online, plural, =0{Play live, nobody else online} other{Play live, {online} online}}'**
  String playLiveSpoken(int online);

  /// After the game line on the front door, following a middle dot: how many other people are online, not counting this device; 0 when nobody else is. Kept short.
  ///
  /// In en, this message translates to:
  /// **'{online} online'**
  String onlineCount(int online);

  /// Button: a new table of the player's own, and a link to send to friends.
  ///
  /// In en, this message translates to:
  /// **'Play friends'**
  String get playFriends;

  /// What live play costs. amount is the price with its currency, e.g. $5.99.
  ///
  /// In en, this message translates to:
  /// **'{amount} a year'**
  String pricePerYear(String amount);

  /// What live play is, where it is offered.
  ///
  /// In en, this message translates to:
  /// **'Four seats, filled with whoever is waiting — or a link you send to three friends.'**
  String get seatsOrFriends;

  /// Button: buy live play.
  ///
  /// In en, this message translates to:
  /// **'Subscribe'**
  String get subscribe;

  /// Under the Subscribe button on the front door.
  ///
  /// In en, this message translates to:
  /// **'Playing alone is free, and we have no plans to change that.'**
  String get aloneIsFree;

  /// Heading while waiting to be seated at a live table.
  ///
  /// In en, this message translates to:
  /// **'Finding players'**
  String get findingPlayers;

  /// While waiting to be seated: seconds waited, how many others are waiting, and that bots fill the empty seats after ten seconds.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s{others, plural, =0{} =1{, 1 other waiting} other{, {others} others waiting}} — bots fill any seat still empty at ten'**
  String waitedLine(int seconds, int others);

  /// Button while waiting to be seated: stop waiting for people and fill the empty seats with bots now.
  ///
  /// In en, this message translates to:
  /// **'Play now with bots'**
  String get playNowWithBots;

  /// Button while waiting to be seated: wait up to five minutes for another person instead of playing bots at ten seconds.
  ///
  /// In en, this message translates to:
  /// **'Wait for a person'**
  String get waitForPerson;

  /// Under waitForPerson: how long it waits, and that the people who run the game are emailed that someone is waiting (no name or address).
  ///
  /// In en, this message translates to:
  /// **'Up to five minutes. We\'re told someone is waiting, and may come and play.'**
  String get waitForPersonHint;

  /// Heading while waiting up to five minutes for another person.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a person'**
  String get waitingForPerson;

  /// While waiting for a person: time waited as minutes:seconds out of five minutes, how many others are waiting, and that bots fill the empty seats after.
  ///
  /// In en, this message translates to:
  /// **'{waited} of 5:00{others, plural, =0{} =1{, 1 other waiting} other{, {others} others waiting}} — then bots fill the empty seats'**
  String waitingForPersonLine(String waited, int others);

  /// Heading after choosing to play now with bots, until the table is ready.
  ///
  /// In en, this message translates to:
  /// **'Seating you with bots'**
  String get seatingWithBots;

  /// Button: stop waiting.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// In a table of the player's own, before anyone has joined.
  ///
  /// In en, this message translates to:
  /// **'Send the link. The table starts ten seconds after someone joins.'**
  String get roomSendLink;

  /// In a table of the player's own: the countdown to the start.
  ///
  /// In en, this message translates to:
  /// **'Starting in {seconds} s — empty seats go to bots'**
  String roomStartingIn(int seconds);

  /// Button: send the link to the player's table.
  ///
  /// In en, this message translates to:
  /// **'Share the link'**
  String get shareTheLink;

  /// The player's own line in the list of who is at the table.
  ///
  /// In en, this message translates to:
  /// **'{name} (you)'**
  String nameIsYou(String name);

  /// An empty line in the list of who is at the table.
  ///
  /// In en, this message translates to:
  /// **'a bot, unless someone joins'**
  String get emptySeat;

  /// Button: start the table without waiting for the countdown.
  ///
  /// In en, this message translates to:
  /// **'Start now'**
  String get startNow;

  /// Button: leave the table before it starts.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// Read by a screen reader beside a player's rating. provisional is true while too few games have settled it.
  ///
  /// In en, this message translates to:
  /// **'rated {rating}{provisional, select, true{, provisionally} other{}}'**
  String ratedSpoken(int rating, String provisional);

  /// Shown when players at one table have different versions of the app.
  ///
  /// In en, this message translates to:
  /// **'Someone\'s app is on another build than yours — one of you is older. Update, and try again.'**
  String get roomOtherBuild;

  /// Shown in a browser when the code that deals the cards fairly has failed.
  ///
  /// In en, this message translates to:
  /// **'The deal that keeps the cards honest stopped working on this page. Reload it to start afresh.'**
  String get noDealPageStopped;

  /// Shown in the app when the code that deals the cards fairly has failed.
  ///
  /// In en, this message translates to:
  /// **'The deal that keeps the cards honest stopped working. Restart the app to start afresh.'**
  String get noDealAppStopped;

  /// Shown in a browser that cannot run the code that deals the cards fairly.
  ///
  /// In en, this message translates to:
  /// **'This browser can\'t run the deal that keeps the cards honest. Try a current Chrome, Firefox or Safari.'**
  String get noDealBrowser;

  /// Shown in an app build that cannot run the code that deals the cards fairly.
  ///
  /// In en, this message translates to:
  /// **'This build can\'t run the deal that keeps the cards honest, so it can\'t sit at a live table.'**
  String get noDealBuild;

  /// Shown when the app's own server cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the service. Try again in a moment.'**
  String get serviceUnreachable;

  /// Shown when a code from another device's screen was made for a different device.
  ///
  /// In en, this message translates to:
  /// **'That code is not for this device.'**
  String get codeNotForThisDevice;

  /// Why the server turned down a request about a subscription's devices.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noSubscription{No subscription.} accountFull{This subscription has all the devices it can take.} notACode{Not a code.} noSuchCode{No such code.} codeUsed{That code has been used.} codeRunOut{That code has run out.} notADevice{Not a device on this subscription.} onAnotherSubscription{This device is on another subscription. Drop it there first.} clockOff{This device\'s clock is out. Set it right and try again.} notAStore{That is not a store the service knows.} noProof{The store gave nothing to show for the purchase.} notFromStore{That purchase did not come from the store.} notPaid{The store says that purchase is not paid for.} storeNotAnswering{The store is not answering. Try again in a moment.} storeNotSetUp{Buying in the store is not open yet.} signInRefused{That sign-in did not check out. Try again.} accountElsewhere{That sign-in is linked to another account.} accountNowhere{No account is linked to that sign-in yet.} otherSignIn{This account is already linked to another sign-in.} signInNotSetUp{Signing in is not open yet.} other{The service turned that down.}}'**
  String serviceRefusal(String reason);

  /// Shown when live play cannot be bought on this device.
  ///
  /// In en, this message translates to:
  /// **'Buying is not open on this device yet.'**
  String get buyingNotOpen;

  /// Shown when the shop cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the shop. Try again in a moment.'**
  String get shopUnreachable;

  /// Shown when the shop is not taking orders.
  ///
  /// In en, this message translates to:
  /// **'The shop is not open yet.'**
  String get shopNotOpen;

  /// On the Live play page once it is bought: the day it runs to, written year-month-day.
  ///
  /// In en, this message translates to:
  /// **'Open on this device, to {day}'**
  String openUntil(String day);

  /// One of the points on the Live play page.
  ///
  /// In en, this message translates to:
  /// **'A rating of your own, from results the four of you sign.'**
  String get pointRating;

  /// One of the points on the Live play page.
  ///
  /// In en, this message translates to:
  /// **'The deal is dealt between the four of you. No server sees a hand, ours included.'**
  String get pointDeal;

  /// On the Live play page, under the points.
  ///
  /// In en, this message translates to:
  /// **'Playing alone is free, and so are the records, the engine and every line of this; we have no plans to change that. What the money pays for is the part that costs us to run: putting you in touch with each other, a relay when your two devices cannot find a way through, and a juror when a table is left alone.'**
  String get whatMoneyPaysFor;

  /// Under the Subscribe button on the web, where Stripe takes the payment and Link, Stripe's affiliate, sells the subscription: the price and that tax is added, that it is a year, that it renews by itself until cancelled, and where to cancel (Manage subscription, on this page once subscribed). California's automatic renewal law asks for all of it beside the button.
  ///
  /// In en, this message translates to:
  /// **'{price} a year plus any tax, sold by Link, Stripe\'s affiliate, on Stripe\'s page. It renews automatically every year until you cancel, at the price then in force: we email you at least 7 days before a new price would apply. Cancel whenever you like under Manage subscription, and live play lasts to the end of the year you paid for.'**
  String webRenewal(String price);

  /// Under the Subscribe button, on the web and in the stores: buying is agreeing to the terms, linked just below.
  ///
  /// In en, this message translates to:
  /// **'By subscribing, you agree to the Terms of use.'**
  String get subscribeAgrees;

  /// On the Subscription page, in place of the price, when the service says this device's account is suspended from live play.
  ///
  /// In en, this message translates to:
  /// **'Suspended from live play'**
  String get accountSuspendedTitle;

  /// On the Subscription page, in place of the Subscribe button: the account is suspended under the terms; solo play still works; how to ask why or appeal.
  ///
  /// In en, this message translates to:
  /// **'This account is suspended from live play under the terms of use. Playing alone is still open to you. To ask why, or to appeal, email help@openhearts.game.'**
  String get accountSuspended;

  /// Under the Subscribe button, on a phone whose store has not said yet what the subscription costs, as when the app opened offline. store is apple or google: the App Store or Google Play.
  ///
  /// In en, this message translates to:
  /// **'{store, select, google{Google Play hasn\'t said what live play costs yet. Check that you\'re online, then tap Subscribe to ask it again.} other{The App Store hasn\'t said what live play costs yet. Check that you\'re online, then tap Subscribe to ask it again.}}'**
  String storeNotAnswered(String store);

  /// On the Live play page once it is bought, above the list of devices.
  ///
  /// In en, this message translates to:
  /// **'A subscription is your account, not a device\'s, and it plays on one device at a time. Bring another in by showing it this code — its camera is all it needs — and drop one whenever you like.'**
  String get subscriptionIsYours;

  /// Heading of the list of devices on the subscription.
  ///
  /// In en, this message translates to:
  /// **'Your devices'**
  String get yourDevices;

  /// Beside Your devices: how many devices are on the subscription, of how many it allows.
  ///
  /// In en, this message translates to:
  /// **'{count} of {most}'**
  String devicesOf(int count, int most);

  /// Button: show a code another device can scan to join the subscription.
  ///
  /// In en, this message translates to:
  /// **'Add a device'**
  String get addDevice;

  /// Under the code to scan.
  ///
  /// In en, this message translates to:
  /// **'Point the other device\'s camera at this. It is good for ten minutes and for one device: a photograph of this screen tomorrow is worth nothing.'**
  String get pointTheCamera;

  /// Button: send the code as a link rather than scanning it.
  ///
  /// In en, this message translates to:
  /// **'Send the link instead'**
  String get sendLinkInstead;

  /// In the list of devices: the one in the player's hand.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get thisDevice;

  /// In the list of devices: the day a device joined, written year-month-day.
  ///
  /// In en, this message translates to:
  /// **'since {day}'**
  String deviceSince(String day);

  /// Button: take the device in the player's hand off the subscription.
  ///
  /// In en, this message translates to:
  /// **'Drop this one'**
  String get dropThisOne;

  /// Button: take a device off the subscription.
  ///
  /// In en, this message translates to:
  /// **'Drop'**
  String get drop;

  /// Read by a screen reader for the code another device scans.
  ///
  /// In en, this message translates to:
  /// **'A code to scan'**
  String get codeToScan;

  /// Shown when the chosen file is not a picture.
  ///
  /// In en, this message translates to:
  /// **'That did not read as a picture.'**
  String get notAPicture;

  /// Shown when the chosen file could not be opened. error is a technical message, in English.
  ///
  /// In en, this message translates to:
  /// **'Could not open that: {error}'**
  String couldNotOpen(String error);

  /// Button: close the page or sheet, keeping what was chosen.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// The field for the player's name, which the others see.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get yourName;

  /// Under the name field, when the name is one the filter refuses (names.dart): the others would not see it, and the last allowed name stays.
  ///
  /// In en, this message translates to:
  /// **'This name isn\'t allowed. Choose another.'**
  String get nameNotAllowed;

  /// Heading above the icons and colours the player can choose.
  ///
  /// In en, this message translates to:
  /// **'How you look'**
  String get howYouLook;

  /// Read by a screen reader for each colour the player can choose.
  ///
  /// In en, this message translates to:
  /// **'Colour {number}'**
  String colourNumber(int number);

  /// Button: choose a photo as the player's picture.
  ///
  /// In en, this message translates to:
  /// **'Use a photo'**
  String get useAPhoto;

  /// Button: go back to the player's initials instead of an icon or photo.
  ///
  /// In en, this message translates to:
  /// **'My initials'**
  String get myInitials;

  /// Read by a screen reader for each icon the player can choose.
  ///
  /// In en, this message translates to:
  /// **'{icon, select, pets{Paw} rabbit{Rabbit} bug{Bug} sailing{Sailing boat} rocket{Rocket} anchor{Anchor} castle{Castle} diamond{Diamond} spa{Leaf} park{Tree} star{Star} bolt{Bolt} sun{Sun} moon{Moon} flower{Flower} cake{Cake} coffee{Coffee} music{Music note} game{Game controller} umbrella{Umbrella} bike{Bicycle} piano{Piano} palette{Palette} other{Snowflake}}'**
  String avatarIcon(String icon);

  /// On the profile: how fast the player plays. pace is brisk, steady, unhurried or slow.
  ///
  /// In en, this message translates to:
  /// **'You play at a {pace, select, brisk{brisk} steady{steady} unhurried{unhurried} slow{slow} other{not yet known}} pace, about {seconds, plural, =1{1 second} other{{seconds} seconds}} a card, and are seated with players at a similar pace'**
  String paceKnown(String pace, int seconds);

  /// On the profile, before the player's pace is known.
  ///
  /// In en, this message translates to:
  /// **'Your pace is not known yet. After a live game or two you will be seated with players at a similar pace'**
  String get paceUnknown;

  /// Heading on the profile.
  ///
  /// In en, this message translates to:
  /// **'Rating'**
  String get rating;

  /// On the profile while the player's games are counted.
  ///
  /// In en, this message translates to:
  /// **'Counting up your games…'**
  String get countingGames;

  /// On the profile when the rating could not be fetched.
  ///
  /// In en, this message translates to:
  /// **'The relays did not answer, so it cannot be shown just now'**
  String get relaysSilent;

  /// On the profile before the player has a rating.
  ///
  /// In en, this message translates to:
  /// **'Play a rated live game and you will have one'**
  String get playRatedForRating;

  /// Under the rating while too few games have settled it.
  ///
  /// In en, this message translates to:
  /// **'{games, plural, =1{Provisional, from one game} other{Provisional, from {games} games}}'**
  String ratingProvisionalFrom(int games);

  /// Under the rating.
  ///
  /// In en, this message translates to:
  /// **'{games, plural, =1{From one game} other{From {games} games}}'**
  String ratingFrom(int games);

  /// Heading of the table of the player's games.
  ///
  /// In en, this message translates to:
  /// **'Your games'**
  String get yourGames;

  /// Column heading: games played live.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get gamesLive;

  /// Column heading: games played against the bots.
  ///
  /// In en, this message translates to:
  /// **'Alone'**
  String get gamesAlone;

  /// Row of the games table: how many were played.
  ///
  /// In en, this message translates to:
  /// **'played'**
  String get gamesPlayed;

  /// Row of the games table: how many were won.
  ///
  /// In en, this message translates to:
  /// **'won'**
  String get gamesWon;

  /// Row of the games table: the average final score.
  ///
  /// In en, this message translates to:
  /// **'average'**
  String get gamesAverage;

  /// Row of the games table: the best (lowest) final score.
  ///
  /// In en, this message translates to:
  /// **'best'**
  String get gamesBest;

  /// Title of the page that crops a photo.
  ///
  /// In en, this message translates to:
  /// **'Your picture'**
  String get yourPicture;

  /// Button: use the photo as cropped.
  ///
  /// In en, this message translates to:
  /// **'Use it'**
  String get useIt;

  /// How to crop the photo.
  ///
  /// In en, this message translates to:
  /// **'Drag to move it, pinch to make it bigger.\nWhat is in the circle is your picture.'**
  String get cropHelp;

  /// When another player's picture has been hidden automatically.
  ///
  /// In en, this message translates to:
  /// **'This device thought this picture was one you would not want at the table. It is a guess, made here, and it can be wrong.'**
  String get pictureFlagged;

  /// Button: show another player's picture.
  ///
  /// In en, this message translates to:
  /// **'Show {name}\'s picture'**
  String showPicture(String name);

  /// Button: hide another player's picture.
  ///
  /// In en, this message translates to:
  /// **'Hide {name}\'s picture'**
  String hidePicture(String name);

  /// Under the show or hide picture button.
  ///
  /// In en, this message translates to:
  /// **'On this device only, and only their picture: their name and their score stay.'**
  String get pictureChoiceNote;

  /// Button and title: report another player to the people who run the game.
  ///
  /// In en, this message translates to:
  /// **'Report {name}'**
  String reportPlayer(String name);

  /// In the report sheet, above the choices of what is reported.
  ///
  /// In en, this message translates to:
  /// **'What\'s wrong?'**
  String get reportWhat;

  /// Report choice: the other player's picture.
  ///
  /// In en, this message translates to:
  /// **'Their picture'**
  String get reportTheirPicture;

  /// Report choice: the other player's name.
  ///
  /// In en, this message translates to:
  /// **'Their name'**
  String get reportTheirName;

  /// Report choice: anything other than the picture or the name.
  ///
  /// In en, this message translates to:
  /// **'Something else'**
  String get reportSomethingElse;

  /// Hint in the report's note field.
  ///
  /// In en, this message translates to:
  /// **'Anything we should know (optional)'**
  String get reportNoteHint;

  /// Under the report's note: who sees a report.
  ///
  /// In en, this message translates to:
  /// **'This goes only to the people who run Open Hearts, with your account number and theirs.'**
  String get reportGoesTo;

  /// Button: send the report.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get reportSend;

  /// After a report has gone.
  ///
  /// In en, this message translates to:
  /// **'Report sent. Thank you.'**
  String get reportSent;

  /// When the service refuses a report as one too many today.
  ///
  /// In en, this message translates to:
  /// **'That\'s as many reports as you can send today.'**
  String get reportTooMany;

  /// When a report could not be sent.
  ///
  /// In en, this message translates to:
  /// **'The report didn\'t go. Try again, or write to help@openhearts.game.'**
  String get reportFailed;

  /// Button: block another player on this device.
  ///
  /// In en, this message translates to:
  /// **'Block {name}'**
  String blockPlayer(String name);

  /// Button, on a blocked player: show them again on this device.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblockPlayer;

  /// Shown in place of the name of a player this device blocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked player'**
  String get blockedPlayer;

  /// Under the block button: what blocking does.
  ///
  /// In en, this message translates to:
  /// **'On this device only: you won\'t see their name, picture or reactions. They aren\'t told.'**
  String get blockNote;

  /// Title of the screen asking a player, once on each device, to agree to the terms before they first play live.
  ///
  /// In en, this message translates to:
  /// **'Before you play live'**
  String get liveAgreeTitle;

  /// What the player is asked before they first play live: to accept the terms, linked below.
  ///
  /// In en, this message translates to:
  /// **'To play live, accept the Terms of use.'**
  String get liveAgreeBody;

  /// Button: accept the terms and go on into live play.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get liveAgree;

  /// Title of the note shown, on a phone, when its store says the player is under 13: live play is closed to them.
  ///
  /// In en, this message translates to:
  /// **'Live play is for 13 and older'**
  String get liveTooYoungTitle;

  /// The note's text: which says so (the player's Apple Account, or Google Play), and that playing alone stays open.
  ///
  /// In en, this message translates to:
  /// **'{store, select, google{Google Play says you\'re under 13.} other{Your Apple Account says you\'re under 13.}} Playing alone is open to everyone, as much as you like.'**
  String liveTooYoung(String store);

  /// Title of the note shown on Android when Google Play is waiting for the player's parent or guardian to approve the app's latest significant changes.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a parent'**
  String get liveAwaitingParentTitle;

  /// The note's text: live play opens once they approve; playing alone stays open.
  ///
  /// In en, this message translates to:
  /// **'Google Play is waiting for a parent or guardian to approve changes to Open Hearts. Live play opens once they do. You can play alone meanwhile.'**
  String get liveAwaitingParent;

  /// Title of the note shown on Android when the player's parent or guardian declined the app's latest significant changes in Google Play.
  ///
  /// In en, this message translates to:
  /// **'Not approved'**
  String get liveParentDeclinedTitle;

  /// The note's text: live play is closed; playing alone stays open.
  ///
  /// In en, this message translates to:
  /// **'A parent or guardian didn\'t approve changes to Open Hearts in Google Play, so live play is closed. You can still play alone.'**
  String get liveParentDeclined;

  /// Title of the note shown on Android when Google Play needs the player to confirm their age, which it asks where a law requires it.
  ///
  /// In en, this message translates to:
  /// **'Confirm your age'**
  String get liveAgeUnconfirmedTitle;

  /// The note's text: confirm in the Play Store app; playing alone stays open meanwhile.
  ///
  /// In en, this message translates to:
  /// **'Google Play needs you to confirm your age before you can play live. You can do it in the Play Store app. You can play alone meanwhile.'**
  String get liveAgeUnconfirmed;

  /// At the front door: the terms of use and the privacy policy have both changed since this device last dismissed a notice.
  ///
  /// In en, this message translates to:
  /// **'Our terms of use and privacy policy have changed.'**
  String get changedBoth;

  /// At the front door: the terms of use have changed since this device last dismissed a notice.
  ///
  /// In en, this message translates to:
  /// **'Our terms of use have changed.'**
  String get changedTerms;

  /// At the front door: the privacy policy has changed since this device last dismissed a notice.
  ///
  /// In en, this message translates to:
  /// **'Our privacy policy has changed.'**
  String get changedPrivacy;

  /// Button beside a notice that the terms or the privacy policy changed, and the title of what it opens: a short summary of each change.
  ///
  /// In en, this message translates to:
  /// **'What changed'**
  String get whatChanged;

  /// Link under the summary of a change to the terms or the privacy policy: opens the whole document.
  ///
  /// In en, this message translates to:
  /// **'Read in full'**
  String get readInFull;

  /// Button on the subscription page, and on the screen that asks: delete this device's account for good.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get deleteAccount;

  /// Title of the screen that asks before an account is deleted.
  ///
  /// In en, this message translates to:
  /// **'Delete your account?'**
  String get deleteAccountTitle;

  /// What deleting an account does, said before it is done: what goes, that the time paid for is lost, and that cancelling is the other way to stop paying.
  ///
  /// In en, this message translates to:
  /// **'This can\'t be undone. It deletes your account on all its devices — its profile, devices, backup codes and sign-in — and takes your name off the games you played. It also clears everything Open Hearts keeps on this device.\n\nLive play stops now, and the time left on your subscription is lost. A web subscription is cancelled. One from the App Store or Google Play goes on renewing until you cancel it there.\n\nTo stop paying but keep playing until your year is up, cancel instead.'**
  String get deleteAccountBody;

  /// Button: do not delete the account after all.
  ///
  /// In en, this message translates to:
  /// **'Keep account'**
  String get keepAccount;

  /// Title of the last screen in a phone build after the account was deleted.
  ///
  /// In en, this message translates to:
  /// **'Your account is deleted'**
  String get accountDeleted;

  /// On the last screen after the account was deleted: a phone app cannot start itself again.
  ///
  /// In en, this message translates to:
  /// **'Close Open Hearts and open it again to start afresh.'**
  String get accountDeletedClose;

  /// Under the table while the game is paused.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the others to reconnect'**
  String get waitingToReconnect;

  /// Under the table while this device hears nothing back from the relay: its own internet connection is down or stalled, and it is reconnecting. The game waits for it.
  ///
  /// In en, this message translates to:
  /// **'Your connection is down — reconnecting'**
  String get connectionDown;

  /// Under the table while other devices online settle a stuck turn.
  ///
  /// In en, this message translates to:
  /// **'Asking the jury'**
  String get askingTheJury;

  /// Under the table while no other device is online to settle a stuck turn.
  ///
  /// In en, this message translates to:
  /// **'Nobody online to draw a jury from — waiting for one'**
  String get noJurorOnline;

  /// Under the table while other devices online settle a stuck turn.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the jury'**
  String get waitingForTheJury;

  /// Under the table while a player who left has their hand opened so a bot can play it.
  ///
  /// In en, this message translates to:
  /// **'Opening a departed player\'s hand'**
  String get openingDepartedHand;

  /// Under the table when no player says they hold the two of clubs.
  ///
  /// In en, this message translates to:
  /// **'Nobody claims the 2♣ — the deal is stuck'**
  String get nobodyClaimsTwo;

  /// Button: remove a player who has run out of time; a bot takes their seat.
  ///
  /// In en, this message translates to:
  /// **'Boot {name}'**
  String bootPlayer(String name);

  /// Title when this device can no longer run the fair deal.
  ///
  /// In en, this message translates to:
  /// **'This device can\'t deal'**
  String get cannotDealTitle;

  /// Under cannotDealTitle.
  ///
  /// In en, this message translates to:
  /// **'The deal stopped working here'**
  String get cannotDealLabel;

  /// Explains cannotDealTitle. reason is a technical message, in English.
  ///
  /// In en, this message translates to:
  /// **'So you have left the table, and the others play on with a bot in your seat. Reloading the page starts the deal afresh. ({reason})'**
  String cannotDealWhy(String reason);

  /// Title when a live game cannot go on.
  ///
  /// In en, this message translates to:
  /// **'Connection failure'**
  String get connectionFailure;

  /// Under connectionFailure: too few of the devices keeping the bots' hands are still online.
  ///
  /// In en, this message translates to:
  /// **'Juror quorum lost'**
  String get jurorQuorumLost;

  /// Explains jurorQuorumLost.
  ///
  /// In en, this message translates to:
  /// **'Too few of the jurors keeping the bot seats are still online, so the hand cannot go on. The game ends here, unscored.'**
  String get jurorQuorumLostWhy;

  /// Button on the sheet after a hand at a live table, where the next hand is already under way.
  ///
  /// In en, this message translates to:
  /// **'On with it'**
  String get onWithIt;

  /// Button: back to the front door.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// At a live table: how many of the people are still connected, and whether the game is rated. rated is rated or unrated.
  ///
  /// In en, this message translates to:
  /// **'{here} of {humans} here  ·  {rated, select, rated{rated} other{unrated}}'**
  String hereCount(int here, int humans, String rated);

  /// Title when the table went on without this player.
  ///
  /// In en, this message translates to:
  /// **'A bot took your seat'**
  String get botTookYourSeat;

  /// Explains botTookYourSeat.
  ///
  /// In en, this message translates to:
  /// **'The table could not hear from you, and went on without you.'**
  String get tableCouldNotHear;

  /// Button: go back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// Under the table before a hand with bots can be dealt.
  ///
  /// In en, this message translates to:
  /// **'Waiting for jury…'**
  String get waitingForJurors;

  /// Under the table while the cards are dealt.
  ///
  /// In en, this message translates to:
  /// **'Dealing'**
  String get dealing;

  /// Under the table during the first step of the fair deal.
  ///
  /// In en, this message translates to:
  /// **'Dealing — keys'**
  String get dealingKeys;

  /// Under the table while each player shuffles in turn.
  ///
  /// In en, this message translates to:
  /// **'Shuffling ({turn} of 4)'**
  String shuffling(int turn);

  /// Under the table during the fair deal.
  ///
  /// In en, this message translates to:
  /// **'Dealing the cards'**
  String get dealingTheCards;

  /// Under the table at the end of the fair deal.
  ///
  /// In en, this message translates to:
  /// **'Opening the cards'**
  String get openingTheCards;

  /// In game options, above the choice of target score.
  ///
  /// In en, this message translates to:
  /// **'The game ends when someone reaches'**
  String get gameEndsAt;

  /// In game options: a target score.
  ///
  /// In en, this message translates to:
  /// **'{target} points'**
  String targetPoints(int target);

  /// In game options, above the choice of rated or unrated.
  ///
  /// In en, this message translates to:
  /// **'Rated games move your rating, and the bots\''**
  String get ratedMovesRatings;

  /// In game options: a rated game.
  ///
  /// In en, this message translates to:
  /// **'Rated'**
  String get rated;

  /// In game options: an unrated game.
  ///
  /// In en, this message translates to:
  /// **'Unrated'**
  String get unrated;

  /// On the About page: a link to the project's repository on GitHub.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get sourceCode;

  /// On the About page: the name of the code's licence, a link to its text.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get licenseName;

  /// On the About page: which build of the app this is.
  ///
  /// In en, this message translates to:
  /// **'Build'**
  String get build;

  /// On the About page: when this build was published.
  ///
  /// In en, this message translates to:
  /// **'Published'**
  String get published;

  /// A small button that appears when a newer build of the web app has been published; tapping it reloads.
  ///
  /// In en, this message translates to:
  /// **'New build available'**
  String get newBuildAvailable;

  /// In place of the live play buttons, while the operator has paused live play for everyone.
  ///
  /// In en, this message translates to:
  /// **'Live play is paused for now. Playing alone is not.'**
  String get livePaused;

  /// Across the top of the front door, in a browser, when a newer version is required.
  ///
  /// In en, this message translates to:
  /// **'This version is out of date. Reload to get the new one.'**
  String get updateDueWeb;

  /// Across the top of the front door, in the app, when a newer version is required.
  ///
  /// In en, this message translates to:
  /// **'This version is out of date. Update the app to get the new one.'**
  String get updateDueApp;

  /// Button beside updateDueWeb: reloads the page onto the new version.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get reload;

  /// Menu item and page title: report a problem.
  ///
  /// In en, this message translates to:
  /// **'Tell us what\'s broken'**
  String get tellUsWhatsBroken;

  /// At the top of the report page.
  ///
  /// In en, this message translates to:
  /// **'What happened, and what did you expect? A sentence or two is plenty.'**
  String get feedbackIntro;

  /// Hint in the empty box the player writes the report in.
  ///
  /// In en, this message translates to:
  /// **'What happened'**
  String get feedbackHint;

  /// Checkbox on the report page, opened from a solo game.
  ///
  /// In en, this message translates to:
  /// **'Send this game\'s record too, so the hand can be replayed'**
  String get feedbackWithRecord;

  /// Heading above the build and device details that go with the report.
  ///
  /// In en, this message translates to:
  /// **'Sent with it'**
  String get feedbackSentWithIt;

  /// Button: send the report.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get feedbackSend;

  /// Under the Send button when reports go to GitHub.
  ///
  /// In en, this message translates to:
  /// **'This opens an issue on GitHub, which anyone can read. Leave out anything private.'**
  String get feedbackIsPublic;

  /// Shown after sending, when the report goes by the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied. Paste it into the page that opened.'**
  String get feedbackCopied;

  /// Shown after sending, on a device that cannot open the page: to is the address.
  ///
  /// In en, this message translates to:
  /// **'Copied. Paste it at {to}'**
  String feedbackCopiedTo(String to);

  /// Heading above the chart of recent solo games' final scores.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Your last game alone} other{Your last {count} games alone}}'**
  String statsRecent(int count);

  /// Read by a screen reader for the chart. scores is the scores separated by commas.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Final score of your last game alone: {scores}. Average {average}.} other{Final scores of your last {count} games alone, oldest first: {scores}. Average {average}.}}'**
  String statsRecentSpoken(int count, String scores, int average);

  /// Label on the chart's average line.
  ///
  /// In en, this message translates to:
  /// **'average {average}'**
  String statsAverage(int average);

  /// Under the chart.
  ///
  /// In en, this message translates to:
  /// **'Final scores, oldest first. Lower is better.'**
  String get statsLowerIsBetter;

  /// Under a number: hands in which the player took the queen of spades.
  ///
  /// In en, this message translates to:
  /// **'Queen of spades taken'**
  String get statsQueens;

  /// Under a number: hands in which the player took all 26 points.
  ///
  /// In en, this message translates to:
  /// **'Moons shot'**
  String get statsMoonsShot;

  /// Under a number: hands in which the player stopped someone else taking all 26.
  ///
  /// In en, this message translates to:
  /// **'Moons blocked'**
  String get statsMoonsBlocked;

  /// Under the three numbers: how many solo hands they count.
  ///
  /// In en, this message translates to:
  /// **'{hands, plural, =1{Over 1 hand alone} other{Over {hands} hands alone}}'**
  String statsOverHands(int hands);

  /// Added to seatScores: where that player sits from the player's own seat. where is left, across or right.
  ///
  /// In en, this message translates to:
  /// **', {where, select, left{on your left} across{across from you} other{on your right}}'**
  String seatWhere(String where);

  /// Said aloud when a trick with points in it is taken. who is youTakeIt or takesIt.
  ///
  /// In en, this message translates to:
  /// **'{who}, {points, plural, =1{1 point} other{{points} points}}'**
  String takesPoints(String who, int points);

  /// Read by a screen reader for each row of the scores after a hand or a game.
  ///
  /// In en, this message translates to:
  /// **'{name}: {delta} this hand, {total} in the game'**
  String sheetRow(String name, int delta, int total);

  /// Title of the question asked when the app is opened from a link that adds this device to someone's live play subscription.
  ///
  /// In en, this message translates to:
  /// **'Join this subscription?'**
  String get joinHouseholdTitle;

  /// Under joinHouseholdTitle.
  ///
  /// In en, this message translates to:
  /// **'This link adds this device to a live play subscription. Join only if it came from you, or from someone you share with.'**
  String get joinHouseholdBody;

  /// Button: join the subscription the link is for.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get join;

  /// Button: do not join; the link is put aside.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// Link on the Live play page to the privacy policy.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get privacyPolicy;

  /// Link on the Live play page to the terms of use.
  ///
  /// In en, this message translates to:
  /// **'Terms of use'**
  String get termsOfUse;

  /// Button on the Live play page for a web subscriber: opens Stripe's billing portal.
  ///
  /// In en, this message translates to:
  /// **'Manage subscription'**
  String get manageSubscription;

  /// Under the Manage subscription button: what it is for.
  ///
  /// In en, this message translates to:
  /// **'Cancel, change the card, or see receipts.'**
  String get manageSubscriptionHint;

  /// Said when a subscription bought in the App Store or Google Play is asked to be managed on the web.
  ///
  /// In en, this message translates to:
  /// **'This subscription is managed where it was bought.'**
  String get managedWhereBought;

  /// Shown when the server took a store purchase but what it gave back was not a licence for this device.
  ///
  /// In en, this message translates to:
  /// **'The service\'s answer was not a licence for this device.'**
  String get licenceNotForThisDevice;

  /// Shown when the App Store or Google Play could not open or finish a purchase.
  ///
  /// In en, this message translates to:
  /// **'The store did not finish the purchase. Try again in a moment.'**
  String get storeFailed;

  /// Shown after Restore purchases when the store account has no subscription to bring back.
  ///
  /// In en, this message translates to:
  /// **'No subscription to restore was found in this store account.'**
  String get nothingToRestore;

  /// Button on the Live play page in the App Store and Google Play builds: brings back a subscription this store account already has.
  ///
  /// In en, this message translates to:
  /// **'Restore purchases'**
  String get restorePurchases;

  /// On the Live play page while the App Store or Google Play holds a purchase for approval (a parent's, or a slow payment method).
  ///
  /// In en, this message translates to:
  /// **'The store is waiting to approve the payment. Live play opens here as soon as it does.'**
  String get storePending;

  /// Under the Subscribe button in the App Store and Google Play builds: the price, that it is a year, that it renews by itself, and how to cancel. The stores require all four. 'store' is apple or google.
  ///
  /// In en, this message translates to:
  /// **'{price} a year, charged to your {store, select, apple{Apple Account} other{Google account}} when you confirm. It renews automatically every year until you cancel, at the price then in force, and {store, select, apple{Apple} other{Google}} tells you before a new price applies. Cancel whenever you like in {store, select, apple{the App Store\'s} other{Google Play\'s}} subscription settings, at least a day before it renews.'**
  String storeRenewal(String price, String store);

  /// Above the Manage subscription button for a subscription bought in the App Store or Google Play. 'store' is apple or google.
  ///
  /// In en, this message translates to:
  /// **'Cancel or change it in {store, select, apple{the App Store} other{Google Play}}.'**
  String manageInStore(String store);

  /// The menu entry and the title of the page where a live-play subscription is bought and managed: devices, cancelling, receipts.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get subscription;

  /// On the front door, back from paying, while the licence it bought is being fetched.
  ///
  /// In en, this message translates to:
  /// **'Finishing your purchase…'**
  String get finishingPurchase;

  /// On the front door when the payment went through but the licence has not arrived after a while.
  ///
  /// In en, this message translates to:
  /// **'Your payment went through. Live play opens as soon as it reaches us — reload in a minute.'**
  String get paidLiveSoon;

  /// Menu item and page title: bring this device onto a subscription already bought, with a code.
  ///
  /// In en, this message translates to:
  /// **'Activate subscription'**
  String get activateSubscription;

  /// On the Activate subscription page.
  ///
  /// In en, this message translates to:
  /// **'Bring this device onto a subscription you already have. Scan the code another of your devices shows under Subscription, or type or paste a code: that one, or a backup code from the email.'**
  String get activateBody;

  /// Label of the field a code is typed or pasted into.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get code;

  /// Button: paste from the clipboard into the code field.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// Shown when the Paste button could not read the clipboard (Safari in an app added to the home screen): how to paste by hand, with the system's own Paste.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the clipboard here. Touch and hold the code field, then choose Paste.'**
  String get pasteByHand;

  /// Button: open the camera to scan another device's code.
  ///
  /// In en, this message translates to:
  /// **'Scan a code'**
  String get scanCode;

  /// Button: spend the code and bring this device onto the subscription.
  ///
  /// In en, this message translates to:
  /// **'Activate'**
  String get activate;

  /// Shown once a code has brought this device onto a subscription.
  ///
  /// In en, this message translates to:
  /// **'Live play is open on this device.'**
  String get activated;

  /// Shown when the camera could not be opened to scan.
  ///
  /// In en, this message translates to:
  /// **'No camera to scan with here. Type or paste the code instead.'**
  String get noCamera;

  /// Under the camera view while scanning.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the code on your other device.'**
  String get pointAtCode;

  /// On the Subscription page, under the code to scan: the same code as text.
  ///
  /// In en, this message translates to:
  /// **'Or type this code on the other device, under Activate subscription:'**
  String get orTypeCode;

  /// Button: copy to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// Shown briefly once something is copied to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// Heading on the Subscription page.
  ///
  /// In en, this message translates to:
  /// **'Backup codes'**
  String get backupCodes;

  /// On the Subscription page, above the backup codes.
  ///
  /// In en, this message translates to:
  /// **'For the day none of your devices is at hand to show a code. Each brings one device onto this subscription, once. Keep them somewhere safe.'**
  String get backupCodesHint;

  /// Button on the Subscription page.
  ///
  /// In en, this message translates to:
  /// **'Show backup codes'**
  String get showBackupCodes;

  /// Beside a backup code that has been used.
  ///
  /// In en, this message translates to:
  /// **'used'**
  String get codeUsedMark;

  /// Button: make five new backup codes in place of these.
  ///
  /// In en, this message translates to:
  /// **'Replace codes'**
  String get replaceCodes;

  /// Title of the dialog asking before replacing backup codes.
  ///
  /// In en, this message translates to:
  /// **'Replace the backup codes?'**
  String get replaceCodesTitle;

  /// In the dialog asking before replacing backup codes.
  ///
  /// In en, this message translates to:
  /// **'These five stop working, and five new ones take their place.'**
  String get replaceCodesBody;

  /// Button in the dialog: replace the backup codes.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// Shown once backup codes are replaced.
  ///
  /// In en, this message translates to:
  /// **'New codes made.'**
  String get codesMade;

  /// Button by the backup codes: email the ones still good to the subscription's address.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailCodes;

  /// Shown once the backup codes have been emailed.
  ///
  /// In en, this message translates to:
  /// **'Sent to the email you subscribed with.'**
  String get codesSent;

  /// Shown when the subscription has no email address (bought in an app store).
  ///
  /// In en, this message translates to:
  /// **'This subscription has no email to send them to.'**
  String get codesNoAddress;

  /// Shown when emailing the backup codes failed.
  ///
  /// In en, this message translates to:
  /// **'Could not email them just now. Try again later.'**
  String get codesNotSent;

  /// On the Subscription page before buying: a link to Activate subscription.
  ///
  /// In en, this message translates to:
  /// **'Have a code? Activate'**
  String get haveACode;

  /// On the About page: a link to the privacy policy, in one word.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get privacyShort;

  /// On the About page: a link to the terms of use, in one word.
  ///
  /// In en, this message translates to:
  /// **'Terms'**
  String get termsShort;

  /// Title of the page that shows a finished live game, hand by hand.
  ///
  /// In en, this message translates to:
  /// **'The game'**
  String get gameTitle;

  /// Shown while the finished game's record is fetched and checked.
  ///
  /// In en, this message translates to:
  /// **'Checking every card of the game.'**
  String get checkingGame;

  /// Shown above the hands already checked while the rest of a finished game is still being checked.
  ///
  /// In en, this message translates to:
  /// **'Checking the rest of the game…'**
  String get stillCheckingGame;

  /// Shown when no record is kept for the game at this address.
  ///
  /// In en, this message translates to:
  /// **'No finished game is kept at this address.'**
  String get noGameHere;

  /// Shown when the kept record fails verification; reason is technical, in English.
  ///
  /// In en, this message translates to:
  /// **'This game\'s record does not check out: {reason}'**
  String gameDoesNotCheck(String reason);

  /// Shown when this device cannot run the deal's cryptography to check the game.
  ///
  /// In en, this message translates to:
  /// **'This device cannot check the deal, so it cannot show the game.'**
  String get cantCheckGame;

  /// Heading for one trick in the game review.
  ///
  /// In en, this message translates to:
  /// **'Trick {trick}'**
  String trickNumber(int trick);

  /// A player with no name in the record, by seat number.
  ///
  /// In en, this message translates to:
  /// **'Player {seat}'**
  String seatPlayer(int seat);

  /// Link on the sheet at the end of a live game: opens the finished game, hand by hand.
  ///
  /// In en, this message translates to:
  /// **'See the whole game'**
  String get seeWholeGame;

  /// Menu item at a live table: shares the address where others can watch the game.
  ///
  /// In en, this message translates to:
  /// **'Share a link to watch'**
  String get shareToWatch;

  /// Marks a game being watched as it is played.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get liveNow;

  /// Under a game being watched live: what a watcher can and cannot see.
  ///
  /// In en, this message translates to:
  /// **'Hands stay hidden until the game is over; then the whole game is here, checked.'**
  String get watchingNote;

  /// A watched game is in its pass.
  ///
  /// In en, this message translates to:
  /// **'Passing cards'**
  String get passingNow;

  /// A watched game's cards are being dealt.
  ///
  /// In en, this message translates to:
  /// **'Dealing'**
  String get dealingNow;

  /// Whose card it is in a watched game.
  ///
  /// In en, this message translates to:
  /// **'{name} to play'**
  String toPlayNow(String name);

  /// Heading on the Subscription page, over signing in with Apple or Google.
  ///
  /// In en, this message translates to:
  /// **'Your account'**
  String get yourAccount;

  /// On a subscriber's Subscription page, above the sign-in buttons: why to sign in, and what is kept of the account.
  ///
  /// In en, this message translates to:
  /// **'Sign in, and a new phone or a browser that has forgotten this one comes back into this account by signing in the same way. All that is kept of the sign-in is a scrambled form of its number: no name, no email.'**
  String get signInToKeep;

  /// On the Subscription page before buying, above the sign-in buttons: signing in brings back a subscription from another device.
  ///
  /// In en, this message translates to:
  /// **'Subscribed already, and signed in on your other device? Sign in the same way to bring this one into your account.'**
  String get signInToBringBack;

  /// On a subscriber's Subscription page once this device has signed in.
  ///
  /// In en, this message translates to:
  /// **'{provider, select, apple{Signed in with Apple.} other{Signed in with Google.}} Sign in the same way on a new phone or in another browser, and this subscription comes with you.'**
  String signedInWith(String provider);

  /// On the Subscription page before buying, once this device has signed in.
  ///
  /// In en, this message translates to:
  /// **'{provider, select, apple{Signed in with Apple.} other{Signed in with Google.}} A subscription bought here stays with your account.'**
  String signedInBeforeBuying(String provider);

  /// A sign-in button's label.
  ///
  /// In en, this message translates to:
  /// **'{provider, select, apple{Sign in with Apple} other{Sign in with Google}}'**
  String signInWith(String provider);

  /// Shown when the account just signed in with is already on another device, above a button that moves it here.
  ///
  /// In en, this message translates to:
  /// **'That sign-in is linked to another Open Hearts account. Use that account on this device? This device leaves the one it is in now.'**
  String get accountElsewhere;

  /// Button: move the signed-in account to this device.
  ///
  /// In en, this message translates to:
  /// **'Use that account here'**
  String get moveAccountHere;

  /// Shown once a subscribed device has signed in.
  ///
  /// In en, this message translates to:
  /// **'Signed in.'**
  String get signedIn;

  /// Shown once an unsubscribed device has signed in with an account that has no subscription.
  ///
  /// In en, this message translates to:
  /// **'Signed in. No account is linked to that sign-in yet: subscribe, then sign in from the subscription page.'**
  String get signedInNoSubscription;

  /// Shown when Apple or Google could not finish signing in.
  ///
  /// In en, this message translates to:
  /// **'Signing in did not finish. Try again in a moment.'**
  String get signInFailed;

  /// Over everything on a device whose account another of its devices has taken up: one device at a time.
  ///
  /// In en, this message translates to:
  /// **'Open Hearts is now open on another device'**
  String get openElsewhereTitle;

  /// Under openElsewhereTitle.
  ///
  /// In en, this message translates to:
  /// **'Your account plays on one device at a time, and the newest one opened wins. This one has stepped back: off the table, the jury and the waiting list. Use it here, and the other one steps back instead.'**
  String get openElsewhereBody;

  /// Asked before this device takes the account from another device of it that is at a live table.
  ///
  /// In en, this message translates to:
  /// **'You\'re in a game on another device'**
  String get inGameElsewhereTitle;

  /// Under inGameElsewhereTitle.
  ///
  /// In en, this message translates to:
  /// **'Continue here? That game will be lost.'**
  String get inGameElsewhereBody;

  /// Button under inGameElsewhereBody: takes the account here, and the game on the other device is lost.
  ///
  /// In en, this message translates to:
  /// **'Continue here'**
  String get continueHere;

  /// Button: takes the account back on this device, and the other device steps back.
  ///
  /// In en, this message translates to:
  /// **'Use it here'**
  String get useItHere;

  /// Where live play would be, on a device that stepped back for another device of its account.
  ///
  /// In en, this message translates to:
  /// **'Your account is in use on another device.'**
  String get liveOpenElsewhere;

  /// Beside a device in the account's list: the one in use now.
  ///
  /// In en, this message translates to:
  /// **'in use'**
  String get deviceInUse;

  /// A game's address opened on a device with no subscription.
  ///
  /// In en, this message translates to:
  /// **'Watching a game, and looking at one played, is part of live play.'**
  String get reviewIsLivePlay;

  /// A game's address opened while the account is playing it.
  ///
  /// In en, this message translates to:
  /// **'This is your own game, still being played. It is here once it is over.'**
  String get reviewOwnGame;

  /// The switch beside the hand that has the app play the player's turns for the rest of the hand. Shown only once nothing they hold can change how the hand comes out. One short word.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get autoSwitch;

  /// What a screen reader says the Auto switch does.
  ///
  /// In en, this message translates to:
  /// **'Auto-play the rest of this hand'**
  String get autoPlayLabel;

  /// Said aloud when the Auto switch appears beside the hand.
  ///
  /// In en, this message translates to:
  /// **'Nothing you hold can change this hand now. Auto plays it out for you.'**
  String get autoOffered;

  /// A quick reaction a player at a live table sends, shown beside their emoji in a bubble by their seat and in the picker. One or two short words. code is nice (👍), ha (😂), wow (😮), ouch (😬), sorry (🙏) or gg (👋, good game).
  ///
  /// In en, this message translates to:
  /// **'{code, select, nice{Nice} ha{Ha} wow{Wow} ouch{Ouch} sorry{Sorry} gg{Good game} other{…}}'**
  String reaction(String code);

  /// What a screen reader says when another player's reaction appears beside their seat: the player's name and the reaction's word, as in 'Bonnie: Nice'.
  ///
  /// In en, this message translates to:
  /// **'{name}: {reaction}'**
  String reactionSaid(String name, String reaction);

  /// The speech-bubble button beside the player's own seat at a live table, which opens the reactions to send; what a screen reader calls it.
  ///
  /// In en, this message translates to:
  /// **'React'**
  String get react;

  /// A switch, under the reactions to send and under a game being watched: stops other players' reactions showing on this device.
  ///
  /// In en, this message translates to:
  /// **'Hide others\' reactions'**
  String get hideReactions;

  /// Menu item on the front door: a first hand of Hearts, taught (tutorial.dart).
  ///
  /// In en, this message translates to:
  /// **'Learn to play'**
  String get learnToPlay;

  /// A link under Play solo on the front door, for a device that has played no game alone and not opened the tutorial: opens it. Hearts is the game's name as the language has it.
  ///
  /// In en, this message translates to:
  /// **'New to Hearts? Learn to play'**
  String get learnToPlayOffer;

  /// Button on a tutorial note the table waits on: the note has been read, and the game goes on.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get tutorialNext;

  /// The tutorial's first note, over the dealt hand: what the game is and what to aim for.
  ///
  /// In en, this message translates to:
  /// **'Four players, thirteen cards each. Every heart you take is a point against you, and the queen of spades is 13. Take as few points as you can.'**
  String get tutorialWelcome;

  /// Tutorial, while the player chooses cards to pass. Pass is the button's own word (passButton).
  ///
  /// In en, this message translates to:
  /// **'First, everyone passes three cards. Choose three you would rather not keep and tap Pass. This time they go to the player on your left.'**
  String get tutorialPass;

  /// Tutorial, once the pass is made: the three cards that came in, which the hand marks with a dot until the first trick.
  ///
  /// In en, this message translates to:
  /// **'Three cards came to you from the player on your right. They are marked with a dot until the first trick is played.'**
  String get tutorialReceived;

  /// Tutorial, when the player holds the 2 of clubs and must play it to start the first trick.
  ///
  /// In en, this message translates to:
  /// **'The 2 of clubs leads the first trick, and you have it. Tap it to play it.'**
  String get tutorialYouLead;

  /// Tutorial, when a bot holds the 2 of clubs and is about to play it to start the first trick. name is the bot's name.
  ///
  /// In en, this message translates to:
  /// **'The 2 of clubs leads the first trick, and {name} has it.'**
  String tutorialTheyLead(String name);

  /// Tutorial, at the player's first turn in a trick whose suit they hold: they must follow it. A card that cannot be played is drawn dimmed, and tapping it says why.
  ///
  /// In en, this message translates to:
  /// **'Play a card of the suit that was led, if you have one. The cards you can\'t play are dimmed: tap one to see why.'**
  String get tutorialFollow;

  /// Tutorial, at the player's first turn in a trick whose suit they hold none of, after the first trick: any card may be played. suit is the suit led.
  ///
  /// In en, this message translates to:
  /// **'{suit, select, clubs{You have no clubs} diamonds{You have no diamonds} spades{You have no spades} other{You have no hearts}}, so any card will do. Any points you play go to whoever takes the trick.'**
  String tutorialNoSuit(String suit);

  /// As tutorialNoSuit, on the first trick, which clubs always lead and where no heart or queen of spades may be played.
  ///
  /// In en, this message translates to:
  /// **'You have no clubs, so you can play another suit, but not a heart or the queen of spades: the first trick carries no points.'**
  String get tutorialNoSuitFirst;

  /// Tutorial, over the first trick once all four cards are on the table: who takes a trick, and who leads after.
  ///
  /// In en, this message translates to:
  /// **'The highest card of the suit that was led takes the trick, with any points in it. Whoever takes it leads the next one.'**
  String get tutorialTrickTaken;

  /// Tutorial, when the hand's first heart is played: hearts are broken (refuseHeartsUnbroken's word), and may be led from now on.
  ///
  /// In en, this message translates to:
  /// **'That\'s the first heart: hearts are broken. Until one had been played, nobody could lead a heart. Now anyone can.'**
  String get tutorialHeartsBroken;

  /// Tutorial, when the queen of spades is played to a trick.
  ///
  /// In en, this message translates to:
  /// **'The queen of spades: 13 points to whoever takes this trick.'**
  String get tutorialQueen;

  /// Tutorial, on the score sheet at the end of its one hand: how a hand is scored, shooting the moon (the language's own word, as shotTheMoon has it), and how a game ends.
  ///
  /// In en, this message translates to:
  /// **'Hearts are a point each, the queen of spades 13. Take all 26 and you shoot the moon: everyone else gets them instead. A game goes on to 50 or 100 points, and the lowest score wins.'**
  String get tutorialScore;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en', 'es', 'fr', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
