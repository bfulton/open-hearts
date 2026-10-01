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
  /// **'Open source, no ads. Play alone or live.'**
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

  /// Under the game options on the front door, before the player's rating is known.
  ///
  /// In en, this message translates to:
  /// **'Four seats, filled with whoever is waiting.'**
  String get fourSeatsWaiting;

  /// Under the game options on the front door. provisional is true while too few games have settled the rating.
  ///
  /// In en, this message translates to:
  /// **'You are rated {rating}{provisional, select, true{, provisionally} other{}}, {games, plural, =1{from 1 rated game} other{from {games} rated games}}.'**
  String youAreRated(int rating, String provisional, int games);

  /// Button: a game with whoever else is waiting online.
  ///
  /// In en, this message translates to:
  /// **'Play live'**
  String get playLive;

  /// Read by a screen reader for the Play live button. online counts this device too.
  ///
  /// In en, this message translates to:
  /// **'{online, plural, =0{Play live, nobody else online} =1{Play live, nobody else online} other{Play live, {online} online}}'**
  String playLiveSpoken(int online);

  /// Under Play live: how many devices are online, this one included.
  ///
  /// In en, this message translates to:
  /// **'{online, plural, =0{Nobody else online} =1{Nobody else online} other{{online} online}}'**
  String onlineCount(int online);

  /// Button: a new table of the player's own, and a link to send to friends.
  ///
  /// In en, this message translates to:
  /// **'Play friends'**
  String get playFriends;

  /// Under the Play friends button.
  ///
  /// In en, this message translates to:
  /// **'A new table, and a link to send. A link from a friend opens theirs.'**
  String get playFriendsDetail;

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
  /// **'Playing alone is free, and always will be.'**
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
  /// **'{reason, select, noSubscription{No subscription.} fiveDevices{Five devices already.} notACode{Not a code.} noSuchCode{No such code.} codeUsed{That code has been used.} codeRunOut{That code has run out.} notADevice{Not a device on this subscription.} onAnotherSubscription{This device is on another subscription. Drop it there first.} clockOff{This device\'s clock is more than five minutes out. Set it right and try again.} other{The service turned that down.}}'**
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
  /// **'Playing alone is free and always will be, and so are the records, the engine and every line of this. What the money pays for is the part that costs us to run: putting you in touch with each other, a relay when your two devices cannot find a way through, and a juror when a table is left alone.'**
  String get whatMoneyPaysFor;

  /// Under the Subscribe button.
  ///
  /// In en, this message translates to:
  /// **'Cancel whenever you like; the year you paid for runs out on its own.'**
  String get cancelWhenever;

  /// Under the Subscribe button, on a device that cannot buy yet.
  ///
  /// In en, this message translates to:
  /// **'On a phone this will be the store\'s own subscription. Until the app is in the stores, live play is bought on the web.'**
  String get storeSubscriptionLater;

  /// On the Live play page once it is bought, above the list of devices.
  ///
  /// In en, this message translates to:
  /// **'A subscription is yours, not a device\'s. Bring another in by showing it this code — its camera is all it needs — and drop one whenever you like.'**
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

  /// Under the table while the game is paused.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the others to reconnect'**
  String get waitingToReconnect;

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
  /// **'Waiting for jurors to hold the bots\' hands'**
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

  /// On the About page.
  ///
  /// In en, this message translates to:
  /// **'Hearts, open source. Play alone against the house, or live: the four of you deal the cards between you, and no server sees a hand.'**
  String get aboutBlurb;

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
  /// **'{build} is up'**
  String buildIsUp(String build);

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
