// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String cardName(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'jack',
      'queen': 'queen',
      'king': 'king',
      'ace': 'ace',
      'other': '$number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'clubs',
      'diamonds': 'diamonds',
      'spades': 'spades',
      'other': 'hearts',
    });
    return '$_temp0 of $_temp1';
  }

  @override
  String cardWithArticle(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'jack',
      'queen': 'queen',
      'king': 'king',
      'ace': 'ace',
      'other': '$number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'clubs',
      'diamonds': 'diamonds',
      'spades': 'spades',
      'other': 'hearts',
    });
    return 'the $_temp0 of $_temp1';
  }

  @override
  String seatLed(String name, String card) {
    return '$name led $card';
  }

  @override
  String seatPlayed(String name, String card) {
    return '$name played $card';
  }

  @override
  String passDirection(String direction) {
    String _temp0 = intl.Intl.selectLogic(direction, {
      'left': 'Pass left',
      'right': 'Pass right',
      'across': 'Pass across',
      'other': 'No pass',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstLead => 'The 2 of clubs leads the first trick';

  @override
  String refuseFollowSuit(String suit) {
    String _temp0 = intl.Intl.selectLogic(suit, {
      'clubs': 'You have to follow clubs',
      'diamonds': 'You have to follow diamonds',
      'spades': 'You have to follow spades',
      'other': 'You have to follow hearts',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstTrickPoints => 'No points on the first trick';

  @override
  String get refuseHeartsUnbroken => 'Hearts aren\'t broken yet';

  @override
  String get refuseOther => 'You cannot play that card';

  @override
  String get you => 'You';

  @override
  String seatNumber(int seat) {
    return 'Seat $seat';
  }

  @override
  String handHeader(int hand, String pass, int target) {
    return 'Hand $hand  ·  $pass  ·  to $target';
  }

  @override
  String get heartsBroken => 'Hearts are broken';

  @override
  String get heartsNotBroken => 'Hearts not broken';

  @override
  String get menu => 'Menu';

  @override
  String get leaveTheTable => 'Leave the table';

  @override
  String get about => 'About';

  @override
  String get language => 'Language';

  @override
  String get deviceLanguage => 'Same as this device';

  @override
  String get recordCopied => 'Record copied';

  @override
  String choosePass(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Choose $count more to pass',
      one: 'Choose 1 more to pass',
    );
    return '$_temp0';
  }

  @override
  String get passButton => 'Pass';

  @override
  String passedYou(String name) {
    return '$name passed you';
  }

  @override
  String passedTo(String name) {
    return 'Passed to $name';
  }

  @override
  String get waitingForOthers => 'Waiting for the others';

  @override
  String seatScores(String name, int total, int taken) {
    return '$name: $total in the game, $taken this hand';
  }

  @override
  String get seatOnTurn => ', on turn';

  @override
  String seatClock(int seconds) {
    return ', $seconds s on the clock';
  }

  @override
  String get youTakeIt => 'You take it';

  @override
  String takesIt(String name) {
    return '$name takes it';
  }

  @override
  String get yourTurn => 'Your turn';

  @override
  String get whatHasGone => 'What has gone';

  @override
  String stillOut(int hearts, String queen) {
    String _temp0 = intl.Intl.pluralLogic(
      hearts,
      locale: localeName,
      other: '$hearts hearts',
      one: '1 heart',
      zero: 'No hearts',
    );
    String _temp1 = intl.Intl.selectLogic(queen, {
      'true': ' and the queen',
      'other': '',
    });
    return '$_temp0$_temp1 still out';
  }

  @override
  String get nextHand => 'Next hand';

  @override
  String get newGame => 'New game';

  @override
  String get playAgain => 'Play again';

  @override
  String handNumber(int hand) {
    return 'Hand $hand';
  }

  @override
  String get youShotTheMoon => 'You shot the moon';

  @override
  String shotTheMoon(String name) {
    return '$name shot the moon';
  }

  @override
  String get shotTheMoonDetail => 'All 26 — everyone else takes them';

  @override
  String get aShareOfIt => 'A share of it';

  @override
  String get youWin => 'You win';

  @override
  String namesTie(String names) {
    return '$names tie';
  }

  @override
  String get listAnd => 'and';

  @override
  String nameWins(String name) {
    return '$name wins';
  }

  @override
  String lowestScoreAfter(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Lowest score after $hands hands',
      one: 'Lowest score after 1 hand',
    );
    return '$_temp0';
  }

  @override
  String get copyRecord => 'Copy record';

  @override
  String ratingNow(String rating) {
    return 'Rating $rating';
  }

  @override
  String ratingMoved(String before, String after) {
    return 'Rating $before → $after';
  }

  @override
  String get tagline => 'Open source Hearts card game, no ads';

  @override
  String get playSolo => 'Play solo';

  @override
  String get stillLookingForRelay => 'Still looking for a relay…';

  @override
  String noRelayTakesEvents(String reason) {
    return 'No relay will take this device\'s events: $reason';
  }

  @override
  String couldNotConnect(String error) {
    return 'Could not connect: $error';
  }

  @override
  String get noRelayAnswered =>
      'No relay answered. Check the connection and try again.';

  @override
  String get tableFilledWithoutYou => 'That table filled up without you';

  @override
  String get linkCopied => 'Link copied';

  @override
  String get livePlay => 'Live play';

  @override
  String get yourProfile => 'Your profile';

  @override
  String get gameOptions => 'Game options';

  @override
  String gameLine(int target, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'rated',
      'other': 'unrated',
    });
    return '$target points · $_temp0';
  }

  @override
  String youAreRated(int rating, String provisional, int games) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisionally',
      'other': '',
    });
    String _temp1 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'from $games rated games',
      one: 'from 1 rated game',
    );
    return 'You are rated $rating$_temp0, $_temp1.';
  }

  @override
  String get playLive => 'Play live';

  @override
  String playLiveSpoken(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: 'Play live, $online online',
      one: 'Play live, nobody else online',
      zero: 'Play live, nobody else online',
    );
    return '$_temp0';
  }

  @override
  String onlineCount(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online online',
      one: 'Nobody else online',
      zero: 'Nobody else online',
    );
    return '$_temp0';
  }

  @override
  String get playFriends => 'Play friends';

  @override
  String pricePerYear(String amount) {
    return '$amount a year';
  }

  @override
  String get seatsOrFriends =>
      'Four seats, filled with whoever is waiting — or a link you send to three friends.';

  @override
  String get subscribe => 'Subscribe';

  @override
  String get aloneIsFree => 'Playing alone is free, and always will be.';

  @override
  String get findingPlayers => 'Finding players';

  @override
  String waitedLine(int seconds, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', $others others waiting',
      one: ', 1 other waiting',
      zero: '',
    );
    return '$seconds s$_temp0 — bots fill any seat still empty at ten';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get roomSendLink =>
      'Send the link. The table starts ten seconds after someone joins.';

  @override
  String roomStartingIn(int seconds) {
    return 'Starting in $seconds s — empty seats go to bots';
  }

  @override
  String get shareTheLink => 'Share the link';

  @override
  String nameIsYou(String name) {
    return '$name (you)';
  }

  @override
  String get emptySeat => 'a bot, unless someone joins';

  @override
  String get startNow => 'Start now';

  @override
  String get leave => 'Leave';

  @override
  String ratedSpoken(int rating, String provisional) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisionally',
      'other': '',
    });
    return 'rated $rating$_temp0';
  }

  @override
  String get roomOtherBuild =>
      'Someone\'s app is on another build than yours — one of you is older. Update, and try again.';

  @override
  String get noDealPageStopped =>
      'The deal that keeps the cards honest stopped working on this page. Reload it to start afresh.';

  @override
  String get noDealAppStopped =>
      'The deal that keeps the cards honest stopped working. Restart the app to start afresh.';

  @override
  String get noDealBrowser =>
      'This browser can\'t run the deal that keeps the cards honest. Try a current Chrome, Firefox or Safari.';

  @override
  String get noDealBuild =>
      'This build can\'t run the deal that keeps the cards honest, so it can\'t sit at a live table.';

  @override
  String get serviceUnreachable =>
      'Could not reach the service. Try again in a moment.';

  @override
  String get codeNotForThisDevice => 'That code is not for this device.';

  @override
  String serviceRefusal(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noSubscription': 'No subscription.',
      'fiveDevices': 'This subscription has all the devices it can take.',
      'notACode': 'Not a code.',
      'noSuchCode': 'No such code.',
      'codeUsed': 'That code has been used.',
      'codeRunOut': 'That code has run out.',
      'notADevice': 'Not a device on this subscription.',
      'onAnotherSubscription':
          'This device is on another subscription. Drop it there first.',
      'clockOff': 'This device\'s clock is out. Set it right and try again.',
      'notAStore': 'That is not a store the service knows.',
      'noProof': 'The store gave nothing to show for the purchase.',
      'notFromStore': 'That purchase did not come from the store.',
      'notPaid': 'The store says that purchase is not paid for.',
      'storeNotAnswering': 'The store is not answering. Try again in a moment.',
      'storeNotSetUp': 'Buying in the store is not open yet.',
      'signInRefused': 'That sign-in did not check out. Try again.',
      'accountElsewhere': 'That sign-in is linked to another account.',
      'accountNowhere': 'No account is linked to that sign-in yet.',
      'otherSignIn': 'This account is already linked to another sign-in.',
      'signInNotSetUp': 'Signing in is not open yet.',
      'other': 'The service turned that down.',
    });
    return '$_temp0';
  }

  @override
  String get buyingNotOpen => 'Buying is not open on this device yet.';

  @override
  String get shopUnreachable =>
      'Could not reach the shop. Try again in a moment.';

  @override
  String get shopNotOpen => 'The shop is not open yet.';

  @override
  String openUntil(String day) {
    return 'Open on this device, to $day';
  }

  @override
  String get pointRating =>
      'A rating of your own, from results the four of you sign.';

  @override
  String get pointDeal =>
      'The deal is dealt between the four of you. No server sees a hand, ours included.';

  @override
  String get whatMoneyPaysFor =>
      'Playing alone is free and always will be, and so are the records, the engine and every line of this. What the money pays for is the part that costs us to run: putting you in touch with each other, a relay when your two devices cannot find a way through, and a juror when a table is left alone.';

  @override
  String get cancelWhenever =>
      'Cancel whenever you like; the year you paid for runs out on its own.';

  @override
  String get storeSubscriptionLater =>
      'On a phone this will be the store\'s own subscription. Until the app is in the stores, live play is bought on the web.';

  @override
  String get subscriptionIsYours =>
      'A subscription is your account, not a device\'s, and it plays on one device at a time. Bring another in by showing it this code — its camera is all it needs — and drop one whenever you like.';

  @override
  String get yourDevices => 'Your devices';

  @override
  String devicesOf(int count, int most) {
    return '$count of $most';
  }

  @override
  String get addDevice => 'Add a device';

  @override
  String get pointTheCamera =>
      'Point the other device\'s camera at this. It is good for ten minutes and for one device: a photograph of this screen tomorrow is worth nothing.';

  @override
  String get sendLinkInstead => 'Send the link instead';

  @override
  String get thisDevice => 'This device';

  @override
  String deviceSince(String day) {
    return 'since $day';
  }

  @override
  String get dropThisOne => 'Drop this one';

  @override
  String get drop => 'Drop';

  @override
  String get codeToScan => 'A code to scan';

  @override
  String get notAPicture => 'That did not read as a picture.';

  @override
  String couldNotOpen(String error) {
    return 'Could not open that: $error';
  }

  @override
  String get done => 'Done';

  @override
  String get yourName => 'Your name';

  @override
  String get howYouLook => 'How you look';

  @override
  String colourNumber(int number) {
    return 'Colour $number';
  }

  @override
  String get useAPhoto => 'Use a photo';

  @override
  String get myInitials => 'My initials';

  @override
  String avatarIcon(String icon) {
    String _temp0 = intl.Intl.selectLogic(icon, {
      'pets': 'Paw',
      'rabbit': 'Rabbit',
      'bug': 'Bug',
      'sailing': 'Sailing boat',
      'rocket': 'Rocket',
      'anchor': 'Anchor',
      'castle': 'Castle',
      'diamond': 'Diamond',
      'spa': 'Leaf',
      'park': 'Tree',
      'star': 'Star',
      'bolt': 'Bolt',
      'sun': 'Sun',
      'moon': 'Moon',
      'flower': 'Flower',
      'cake': 'Cake',
      'coffee': 'Coffee',
      'music': 'Music note',
      'game': 'Game controller',
      'umbrella': 'Umbrella',
      'bike': 'Bicycle',
      'piano': 'Piano',
      'palette': 'Palette',
      'other': 'Snowflake',
    });
    return '$_temp0';
  }

  @override
  String paceKnown(String pace, int seconds) {
    String _temp0 = intl.Intl.selectLogic(pace, {
      'brisk': 'brisk',
      'steady': 'steady',
      'unhurried': 'unhurried',
      'slow': 'slow',
      'other': 'not yet known',
    });
    String _temp1 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds',
      one: '1 second',
    );
    return 'You play at a $_temp0 pace, about $_temp1 a card, and are seated with players at a similar pace';
  }

  @override
  String get paceUnknown =>
      'Your pace is not known yet. After a live game or two you will be seated with players at a similar pace';

  @override
  String get rating => 'Rating';

  @override
  String get countingGames => 'Counting up your games…';

  @override
  String get relaysSilent =>
      'The relays did not answer, so it cannot be shown just now';

  @override
  String get playRatedForRating =>
      'Play a rated live game and you will have one';

  @override
  String ratingProvisionalFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Provisional, from $games games',
      one: 'Provisional, from one game',
    );
    return '$_temp0';
  }

  @override
  String ratingFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'From $games games',
      one: 'From one game',
    );
    return '$_temp0';
  }

  @override
  String get yourGames => 'Your games';

  @override
  String get gamesLive => 'Live';

  @override
  String get gamesAlone => 'Alone';

  @override
  String get gamesPlayed => 'played';

  @override
  String get gamesWon => 'won';

  @override
  String get gamesAverage => 'average';

  @override
  String get gamesBest => 'best';

  @override
  String get yourPicture => 'Your picture';

  @override
  String get useIt => 'Use it';

  @override
  String get cropHelp =>
      'Drag to move it, pinch to make it bigger.\nWhat is in the circle is your picture.';

  @override
  String get pictureFlagged =>
      'This device thought this picture was one you would not want at the table. It is a guess, made here, and it can be wrong.';

  @override
  String showPicture(String name) {
    return 'Show $name\'s picture';
  }

  @override
  String hidePicture(String name) {
    return 'Hide $name\'s picture';
  }

  @override
  String get pictureChoiceNote =>
      'On this device only, and only their picture: their name and their score stay.';

  @override
  String get waitingToReconnect => 'Waiting for the others to reconnect';

  @override
  String get askingTheJury => 'Asking the jury';

  @override
  String get noJurorOnline =>
      'Nobody online to draw a jury from — waiting for one';

  @override
  String get waitingForTheJury => 'Waiting for the jury';

  @override
  String get openingDepartedHand => 'Opening a departed player\'s hand';

  @override
  String get nobodyClaimsTwo => 'Nobody claims the 2♣ — the deal is stuck';

  @override
  String bootPlayer(String name) {
    return 'Boot $name';
  }

  @override
  String get cannotDealTitle => 'This device can\'t deal';

  @override
  String get cannotDealLabel => 'The deal stopped working here';

  @override
  String cannotDealWhy(String reason) {
    return 'So you have left the table, and the others play on with a bot in your seat. Reloading the page starts the deal afresh. ($reason)';
  }

  @override
  String get connectionFailure => 'Connection failure';

  @override
  String get jurorQuorumLost => 'Juror quorum lost';

  @override
  String get jurorQuorumLostWhy =>
      'Too few of the jurors keeping the bot seats are still online, so the hand cannot go on. The game ends here, unscored.';

  @override
  String get onWithIt => 'On with it';

  @override
  String get home => 'Home';

  @override
  String hereCount(int here, int humans, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'rated',
      'other': 'unrated',
    });
    return '$here of $humans here  ·  $_temp0';
  }

  @override
  String get botTookYourSeat => 'A bot took your seat';

  @override
  String get tableCouldNotHear =>
      'The table could not hear from you, and went on without you.';

  @override
  String get back => 'Back';

  @override
  String get waitingForJurors => 'Waiting for jury…';

  @override
  String get dealing => 'Dealing';

  @override
  String get dealingKeys => 'Dealing — keys';

  @override
  String shuffling(int turn) {
    return 'Shuffling ($turn of 4)';
  }

  @override
  String get dealingTheCards => 'Dealing the cards';

  @override
  String get openingTheCards => 'Opening the cards';

  @override
  String get gameEndsAt => 'The game ends when someone reaches';

  @override
  String targetPoints(int target) {
    return '$target points';
  }

  @override
  String get ratedMovesRatings =>
      'Rated games move your rating, and the bots\'';

  @override
  String get rated => 'Rated';

  @override
  String get unrated => 'Unrated';

  @override
  String get sourceCode => 'Code';

  @override
  String get licenseName => 'License';

  @override
  String get build => 'Build';

  @override
  String get published => 'Published';

  @override
  String get newBuildAvailable => 'New build available';

  @override
  String get livePaused => 'Live play is paused for now. Playing alone is not.';

  @override
  String get updateDueWeb =>
      'This version is out of date. Reload to get the new one.';

  @override
  String get updateDueApp =>
      'This version is out of date. Update the app to get the new one.';

  @override
  String get reload => 'Reload';

  @override
  String get tellUsWhatsBroken => 'Tell us what\'s broken';

  @override
  String get feedbackIntro =>
      'What happened, and what did you expect? A sentence or two is plenty.';

  @override
  String get feedbackHint => 'What happened';

  @override
  String get feedbackWithRecord =>
      'Send this game\'s record too, so the hand can be replayed';

  @override
  String get feedbackSentWithIt => 'Sent with it';

  @override
  String get feedbackSend => 'Send';

  @override
  String get feedbackIsPublic =>
      'This opens an issue on GitHub, which anyone can read. Leave out anything private.';

  @override
  String get feedbackCopied => 'Copied. Paste it into the page that opened.';

  @override
  String feedbackCopiedTo(String to) {
    return 'Copied. Paste it at $to';
  }

  @override
  String statsRecent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Your last $count games alone',
      one: 'Your last game alone',
    );
    return '$_temp0';
  }

  @override
  String statsRecentSpoken(int count, String scores, int average) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Final scores of your last $count games alone, oldest first: $scores. Average $average.',
      one: 'Final score of your last game alone: $scores. Average $average.',
    );
    return '$_temp0';
  }

  @override
  String statsAverage(int average) {
    return 'average $average';
  }

  @override
  String get statsLowerIsBetter =>
      'Final scores, oldest first. Lower is better.';

  @override
  String get statsQueens => 'Queen of spades taken';

  @override
  String get statsMoonsShot => 'Moons shot';

  @override
  String get statsMoonsBlocked => 'Moons blocked';

  @override
  String statsOverHands(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Over $hands hands alone',
      one: 'Over 1 hand alone',
    );
    return '$_temp0';
  }

  @override
  String seatWhere(String where) {
    String _temp0 = intl.Intl.selectLogic(where, {
      'left': 'on your left',
      'across': 'across from you',
      'other': 'on your right',
    });
    return ', $_temp0';
  }

  @override
  String takesPoints(String who, int points) {
    String _temp0 = intl.Intl.pluralLogic(
      points,
      locale: localeName,
      other: '$points points',
      one: '1 point',
    );
    return '$who, $_temp0';
  }

  @override
  String sheetRow(String name, int delta, int total) {
    return '$name: $delta this hand, $total in the game';
  }

  @override
  String get joinHouseholdTitle => 'Join this subscription?';

  @override
  String get joinHouseholdBody =>
      'This link adds this device to a live play subscription. Join only if it came from you, or from someone you share with.';

  @override
  String get join => 'Join';

  @override
  String get notNow => 'Not now';

  @override
  String get privacyPolicy => 'Privacy policy';

  @override
  String get termsOfUse => 'Terms of use';

  @override
  String get manageSubscription => 'Manage subscription';

  @override
  String get manageSubscriptionHint =>
      'Cancel, change the card, or see receipts.';

  @override
  String get managedWhereBought =>
      'This subscription is managed where it was bought.';

  @override
  String get licenceNotForThisDevice =>
      'The service\'s answer was not a licence for this device.';

  @override
  String get storeFailed =>
      'The store did not finish the purchase. Try again in a moment.';

  @override
  String get nothingToRestore =>
      'No subscription to restore was found in this store account.';

  @override
  String get restorePurchases => 'Restore purchases';

  @override
  String get storePending =>
      'The store is waiting to approve the payment. Live play opens here as soon as it does.';

  @override
  String storeRenewal(String price, String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'Apple Account',
      'other': 'Google account',
    });
    String _temp1 = intl.Intl.selectLogic(store, {
      'apple': 'the App Store\'s',
      'other': 'Google Play\'s',
    });
    return '$price a year, charged to your $_temp0 when you confirm. It renews by itself every year until you cancel, which you can do whenever you like in $_temp1 subscription settings, at least a day before it renews.';
  }

  @override
  String manageInStore(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'the App Store',
      'other': 'Google Play',
    });
    return 'Cancel or change it in $_temp0.';
  }

  @override
  String get subscription => 'Subscription';

  @override
  String get finishingPurchase => 'Finishing your purchase…';

  @override
  String get paidLiveSoon =>
      'Your payment went through. Live play opens as soon as it reaches us — reload in a minute.';

  @override
  String get checkingOnline => 'Checking online players…';

  @override
  String get activateSubscription => 'Activate subscription';

  @override
  String get activateBody =>
      'Bring this device onto a subscription you already have. Scan the code another of your devices shows under Subscription, or type or paste a code: that one, or a backup code from the email.';

  @override
  String get code => 'Code';

  @override
  String get paste => 'Paste';

  @override
  String get pasteByHand =>
      'Couldn\'t read the clipboard here. Touch and hold the code field, then choose Paste.';

  @override
  String get scanCode => 'Scan a code';

  @override
  String get activate => 'Activate';

  @override
  String get activated => 'Live play is open on this device.';

  @override
  String get noCamera =>
      'No camera to scan with here. Type or paste the code instead.';

  @override
  String get pointAtCode =>
      'Point the camera at the code on your other device.';

  @override
  String get orTypeCode =>
      'Or type this code on the other device, under Activate subscription:';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get backupCodes => 'Backup codes';

  @override
  String get backupCodesHint =>
      'For the day none of your devices is at hand to show a code. Each brings one device onto this subscription, once. Keep them somewhere safe.';

  @override
  String get showBackupCodes => 'Show backup codes';

  @override
  String get codeUsedMark => 'used';

  @override
  String get replaceCodes => 'Replace codes';

  @override
  String get replaceCodesTitle => 'Replace the backup codes?';

  @override
  String get replaceCodesBody =>
      'These five stop working, and five new ones take their place.';

  @override
  String get replace => 'Replace';

  @override
  String get codesMade => 'New codes made.';

  @override
  String get emailCodes => 'Email';

  @override
  String get codesSent => 'Sent to the email you subscribed with.';

  @override
  String get codesNoAddress =>
      'This subscription has no email to send them to.';

  @override
  String get codesNotSent => 'Could not email them just now. Try again later.';

  @override
  String get haveACode => 'Have a code? Activate';

  @override
  String get privacyShort => 'Privacy';

  @override
  String get termsShort => 'Terms';

  @override
  String get gameTitle => 'The game';

  @override
  String get checkingGame => 'Checking every card of the game.';

  @override
  String get stillCheckingGame => 'Checking the rest of the game…';

  @override
  String get noGameHere => 'No finished game is kept at this address.';

  @override
  String gameDoesNotCheck(String reason) {
    return 'This game\'s record does not check out: $reason';
  }

  @override
  String get cantCheckGame =>
      'This device cannot check the deal, so it cannot show the game.';

  @override
  String trickNumber(int trick) {
    return 'Trick $trick';
  }

  @override
  String seatPlayer(int seat) {
    return 'Player $seat';
  }

  @override
  String get seeWholeGame => 'See the whole game';

  @override
  String get shareToWatch => 'Share a link to watch';

  @override
  String get liveNow => 'Live';

  @override
  String get watchingNote =>
      'Hands stay hidden until the game is over; then the whole game is here, checked.';

  @override
  String get passingNow => 'Passing cards';

  @override
  String get dealingNow => 'Dealing';

  @override
  String toPlayNow(String name) {
    return '$name to play';
  }

  @override
  String get yourAccount => 'Your account';

  @override
  String get signInToKeep =>
      'Sign in, and a new phone or a browser that has forgotten this one comes back into this account by signing in the same way. All that is kept of the sign-in is a scrambled form of its number: no name, no email.';

  @override
  String get signInToBringBack =>
      'Subscribed already, and signed in on your other device? Sign in the same way to bring this one into your account.';

  @override
  String signedInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Signed in with Apple.',
      'other': 'Signed in with Google.',
    });
    return '$_temp0 Sign in the same way on a new phone or in another browser, and this subscription comes with you.';
  }

  @override
  String signedInBeforeBuying(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Signed in with Apple.',
      'other': 'Signed in with Google.',
    });
    return '$_temp0 A subscription bought here stays with your account.';
  }

  @override
  String signInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Sign in with Apple',
      'other': 'Sign in with Google',
    });
    return '$_temp0';
  }

  @override
  String get accountElsewhere =>
      'That sign-in is linked to another Open Hearts account. Use that account on this device? This device leaves the one it is in now.';

  @override
  String get moveAccountHere => 'Use that account here';

  @override
  String get signedIn => 'Signed in.';

  @override
  String get signedInNoSubscription =>
      'Signed in. No account is linked to that sign-in yet: subscribe, then sign in from the subscription page.';

  @override
  String get signInFailed =>
      'Signing in did not finish. Try again in a moment.';

  @override
  String get openElsewhereTitle => 'Open Hearts is now open on another device';

  @override
  String get openElsewhereBody =>
      'Your account plays on one device at a time, and the newest one opened wins. This one has stepped back: off the table, the jury and the waiting list. Use it here, and the other one steps back instead.';

  @override
  String get inGameElsewhereTitle => 'You\'re in a game on another device';

  @override
  String get inGameElsewhereBody => 'Continue here? That game will be lost.';

  @override
  String get continueHere => 'Continue here';

  @override
  String get useItHere => 'Use it here';

  @override
  String get liveOpenElsewhere => 'Your account is in use on another device.';

  @override
  String get deviceInUse => 'in use';

  @override
  String get reviewIsLivePlay =>
      'Watching a game, and looking at one played, is part of live play.';

  @override
  String get reviewOwnGame =>
      'This is your own game, still being played. It is here once it is over.';

  @override
  String get autoSwitch => 'Auto';

  @override
  String get autoPlayLabel => 'Auto-play the rest of this hand';

  @override
  String get autoOffered =>
      'Nothing you hold can change this hand now. Auto plays it out for you.';
}
