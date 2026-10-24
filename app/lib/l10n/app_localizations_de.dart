// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String cardName(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(suit, {
      'clubs': 'Kreuz',
      'diamonds': 'Karo',
      'spades': 'Pik',
      'other': 'Herz',
    });
    String _temp1 = intl.Intl.selectLogic(rank, {
      'jack': 'Bube',
      'queen': 'Dame',
      'king': 'König',
      'ace': 'Ass',
      'other': '$number',
    });
    return '$_temp0 $_temp1';
  }

  @override
  String cardWithArticle(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'den',
      'queen': 'die',
      'king': 'den',
      'ace': 'das',
      'other': 'die',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'Kreuz',
      'diamonds': 'Karo',
      'spades': 'Pik',
      'other': 'Herz',
    });
    String _temp2 = intl.Intl.selectLogic(rank, {
      'jack': 'Buben',
      'queen': 'Dame',
      'king': 'König',
      'ace': 'Ass',
      'other': '$number',
    });
    return '$_temp0 $_temp1-$_temp2';
  }

  @override
  String seatLed(String name, String card) {
    return '$name spielte $card aus';
  }

  @override
  String seatPlayed(String name, String card) {
    return '$name spielte $card';
  }

  @override
  String passDirection(String direction) {
    String _temp0 = intl.Intl.selectLogic(direction, {
      'left': 'Nach links geben',
      'right': 'Nach rechts geben',
      'across': 'Gegenüber geben',
      'other': 'Kein Tausch',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstLead => 'Kreuz 2 spielt den ersten Stich aus';

  @override
  String refuseFollowSuit(String suit) {
    String _temp0 = intl.Intl.selectLogic(suit, {
      'clubs': 'Du musst Kreuz bedienen',
      'diamonds': 'Du musst Karo bedienen',
      'spades': 'Du musst Pik bedienen',
      'other': 'Du musst Herz bedienen',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstTrickPoints => 'Keine Punkte im ersten Stich';

  @override
  String get refuseHeartsUnbroken => 'Herz ist noch nicht gebrochen';

  @override
  String get refuseOther => 'Diese Karte kannst du nicht spielen';

  @override
  String get you => 'Du';

  @override
  String seatNumber(int seat) {
    return 'Platz $seat';
  }

  @override
  String handHeader(int hand, String pass, int target) {
    return 'Runde $hand  ·  $pass  ·  bis $target';
  }

  @override
  String handHeaderShort(int hand, String pass) {
    return 'Runde $hand  ·  $pass';
  }

  @override
  String get heartsBroken => 'Herz ist gebrochen';

  @override
  String get heartsNotBroken => 'Herz ist nicht gebrochen';

  @override
  String get menu => 'Menü';

  @override
  String get leaveTheTable => 'Tisch verlassen';

  @override
  String get about => 'Über';

  @override
  String get language => 'Sprache';

  @override
  String get deviceLanguage => 'Wie auf diesem Gerät';

  @override
  String get recordCopied => 'Spielprotokoll kopiert';

  @override
  String choosePass(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Noch $count Karten zum Weitergeben wählen',
      one: 'Noch 1 Karte zum Weitergeben wählen',
    );
    return '$_temp0';
  }

  @override
  String choosePassShort(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Noch $count wählen',
      one: 'Noch 1 wählen',
    );
    return '$_temp0';
  }

  @override
  String get passButton => 'Geben';

  @override
  String passedYou(String name) {
    return '$name gab dir';
  }

  @override
  String passedTo(String name) {
    return 'An $name gegeben';
  }

  @override
  String get waitingForOthers => 'Warte auf die anderen';

  @override
  String seatScores(String name, int total, int taken) {
    return '$name: $total im Spiel, $taken in dieser Runde';
  }

  @override
  String get seatOnTurn => ', am Zug';

  @override
  String get seatIsBot => ', ein Bot';

  @override
  String get botTag => 'Bot';

  @override
  String seatClock(int seconds) {
    return ', $seconds s auf der Uhr';
  }

  @override
  String get youTakeIt => 'Dein Stich';

  @override
  String takesIt(String name) {
    return 'Stich für $name';
  }

  @override
  String get yourTurn => 'Du bist dran';

  @override
  String get whatHasGone => 'Schon gespielt';

  @override
  String stillOut(int hearts, String queen) {
    String _temp0 = intl.Intl.pluralLogic(
      hearts,
      locale: localeName,
      other: '$hearts Herz',
      one: '1 Herz',
      zero: 'Kein Herz',
    );
    String _temp1 = intl.Intl.selectLogic(queen, {
      'true': ' und die Dame',
      'other': '',
    });
    return '$_temp0$_temp1 noch im Spiel';
  }

  @override
  String get nextHand => 'Nächste Runde';

  @override
  String get newGame => 'Neues Spiel';

  @override
  String get playAgain => 'Nochmal spielen';

  @override
  String handNumber(int hand) {
    return 'Runde $hand';
  }

  @override
  String get youShotTheMoon => 'Du hast den Durchmarsch geschafft';

  @override
  String shotTheMoon(String name) {
    return '$name hat den Durchmarsch geschafft';
  }

  @override
  String get shotTheMoonDetail => 'Alle 26 — die bekommen alle anderen';

  @override
  String get aShareOfIt => 'Geteilter Sieg';

  @override
  String get youWin => 'Du gewinnst';

  @override
  String namesTie(String names) {
    return 'Gleichstand: $names';
  }

  @override
  String get listAnd => 'und';

  @override
  String nameWins(String name) {
    return '$name gewinnt';
  }

  @override
  String lowestScoreAfter(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Niedrigste Punktzahl nach $hands Runden',
      one: 'Niedrigste Punktzahl nach 1 Runde',
    );
    return '$_temp0';
  }

  @override
  String get copyRecord => 'Protokoll kopieren';

  @override
  String ratingNow(String rating) {
    return 'Wertung $rating';
  }

  @override
  String ratingMoved(String before, String after) {
    return 'Wertung $before → $after';
  }

  @override
  String get tagline => 'Open-Source-Kartenspiel, ohne Werbung';

  @override
  String get playSolo => 'Allein spielen';

  @override
  String get stillLookingForRelay => 'Suche noch ein Relay…';

  @override
  String noRelayTakesEvents(String reason) {
    return 'Kein Relay nimmt die Nachrichten dieses Geräts an: $reason';
  }

  @override
  String couldNotConnect(String error) {
    return 'Verbindung fehlgeschlagen: $error';
  }

  @override
  String get noRelayAnswered =>
      'Kein Relay hat geantwortet. Prüfe die Verbindung und versuch es noch einmal.';

  @override
  String get tableFilledWithoutYou => 'Der Tisch hat sich ohne dich gefüllt';

  @override
  String get linkCopied => 'Link kopiert';

  @override
  String get livePlay => 'Live spielen';

  @override
  String get yourProfile => 'Dein Profil';

  @override
  String get gameOptions => 'Spieloptionen';

  @override
  String gameLine(int target, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'gewertet',
      'other': 'ungewertet',
    });
    return '$target Punkte · $_temp0';
  }

  @override
  String get playLive => 'Live spielen';

  @override
  String playLiveSpoken(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: 'Live spielen, $online online',
      zero: 'Live spielen, sonst niemand online',
    );
    return '$_temp0';
  }

  @override
  String onlineCount(int online) {
    return '$online online';
  }

  @override
  String get playFriends => 'Mit Freunden spielen';

  @override
  String pricePerYear(String amount) {
    return '$amount im Jahr';
  }

  @override
  String get seatsOrFriends =>
      'Vier Plätze, für alle, die gerade warten — oder ein Link, den du an drei Freunde schickst.';

  @override
  String get subscribe => 'Abonnieren';

  @override
  String get aloneIsFree =>
      'Allein spielen ist kostenlos, und wir haben nicht vor, das zu ändern.';

  @override
  String get findingPlayers => 'Suche Mitspieler';

  @override
  String waitedLine(int seconds, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', $others weitere warten',
      one: ', 1 weitere Person wartet',
      zero: '',
    );
    return '$seconds s$_temp0 — nach zehn füllen Bots die leeren Plätze';
  }

  @override
  String get playNowWithBots => 'Jetzt mit Bots spielen';

  @override
  String get waitForPerson => 'Auf einen Menschen warten';

  @override
  String get waitForPersonHint =>
      'Bis zu fünf Minuten. Wir erfahren, dass jemand wartet, und kommen vielleicht zum Spielen.';

  @override
  String get waitingForPerson => 'Warte auf einen Menschen';

  @override
  String waitingForPersonLine(String waited, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', $others weitere warten',
      one: ', 1 weitere Person wartet',
      zero: '',
    );
    return '$waited von 5:00$_temp0 — dann füllen Bots die leeren Plätze';
  }

  @override
  String get seatingWithBots => 'Du bekommst einen Tisch mit Bots';

  @override
  String get cancel => 'Abbrechen';

  @override
  String get roomSendLink =>
      'Schick den Link. Der Tisch startet zehn Sekunden, nachdem jemand dazukommt.';

  @override
  String roomStartingIn(int seconds) {
    return 'Start in $seconds s — leere Plätze bekommen Bots';
  }

  @override
  String get shareTheLink => 'Link teilen';

  @override
  String nameIsYou(String name) {
    return '$name (du)';
  }

  @override
  String get emptySeat => 'ein Bot, außer jemand kommt dazu';

  @override
  String get startNow => 'Jetzt starten';

  @override
  String get leave => 'Verlassen';

  @override
  String ratedSpoken(int rating, String provisional) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', vorläufig',
      'other': '',
    });
    return 'Wertung $rating$_temp0';
  }

  @override
  String get roomOtherBuild =>
      'Jemand hat eine andere App-Version als du — eine davon ist älter. Aktualisiere und versuch es noch einmal.';

  @override
  String get noDealPageStopped =>
      'Das Austeilen, das die Karten ehrlich hält, funktioniert auf dieser Seite nicht mehr. Lade sie neu, um von vorn zu beginnen.';

  @override
  String get noDealAppStopped =>
      'Das Austeilen, das die Karten ehrlich hält, funktioniert nicht mehr. Starte die App neu, um von vorn zu beginnen.';

  @override
  String get noDealBrowser =>
      'Dieser Browser kann das Austeilen, das die Karten ehrlich hält, nicht ausführen. Versuch es mit einem aktuellen Chrome, Firefox oder Safari.';

  @override
  String get noDealBuild =>
      'Diese Version kann das Austeilen, das die Karten ehrlich hält, nicht ausführen und darum an keinem Live-Tisch sitzen.';

  @override
  String get serviceUnreachable =>
      'Der Dienst ist nicht erreichbar. Versuch es gleich noch einmal.';

  @override
  String get codeNotForThisDevice => 'Dieser Code ist nicht für dieses Gerät.';

  @override
  String serviceRefusal(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noSubscription': 'Kein Abo.',
      'accountFull':
          'Dieses Abo hat schon so viele Geräte, wie es tragen kann.',
      'notACode': 'Das ist kein Code.',
      'noSuchCode': 'Diesen Code gibt es nicht.',
      'codeUsed': 'Dieser Code wurde schon benutzt.',
      'codeRunOut': 'Dieser Code ist abgelaufen.',
      'notADevice': 'Dieses Gerät gehört nicht zu diesem Abo.',
      'onAnotherSubscription':
          'Dieses Gerät gehört zu einem anderen Abo. Entferne es dort zuerst.',
      'clockOff': 'Die Uhr dieses Geräts geht falsch. Stell sie richtig und versuch es noch einmal.',
      'notAStore': 'Diesen Store kennt der Dienst nicht.',
      'noProof': 'Der Store hat keinen Beleg für den Kauf geliefert.',
      'notFromStore': 'Dieser Kauf kommt nicht aus dem Store.',
      'notPaid': 'Laut Store ist dieser Kauf nicht bezahlt.',
      'storeNotAnswering':
          'Der Store antwortet nicht. Versuch es gleich noch einmal.',
      'storeNotSetUp': 'Kaufen im Store ist noch nicht geöffnet.',
      'signInRefused':
          'Diese Anmeldung ließ sich nicht prüfen. Versuch es noch einmal.',
      'accountElsewhere':
          'Diese Anmeldung ist mit einem anderen Konto verknüpft.',
      'accountNowhere': 'Mit dieser Anmeldung ist noch kein Konto verknüpft.',
      'otherSignIn':
          'Dieses Konto ist schon mit einer anderen Anmeldung verknüpft.',
      'signInNotSetUp': 'Die Anmeldung ist noch nicht geöffnet.',
      'other': 'Der Dienst hat abgelehnt.',
    });
    return '$_temp0';
  }

  @override
  String get buyingNotOpen => 'Auf diesem Gerät kann man noch nicht kaufen.';

  @override
  String get shopUnreachable =>
      'Der Shop ist nicht erreichbar. Versuch es gleich noch einmal.';

  @override
  String get shopNotOpen => 'Der Shop ist noch nicht geöffnet.';

  @override
  String openUntil(String day) {
    return 'Auf diesem Gerät freigeschaltet bis $day';
  }

  @override
  String get pointRating =>
      'Eine eigene Wertung, aus Ergebnissen, die ihr vier unterschreibt.';

  @override
  String get pointDeal =>
      'Die Karten werden unter euch vieren ausgeteilt. Kein Server sieht eine Hand, auch unserer nicht.';

  @override
  String get whatMoneyPaysFor =>
      'Allein spielen ist kostenlos, genau wie die Protokolle, die Engine und jede Zeile hiervon, und wir haben nicht vor, das zu ändern. Das Geld bezahlt den Teil, dessen Betrieb uns etwas kostet: euch miteinander zu verbinden, ein Relay, wenn zwei Geräte keinen direkten Weg finden, und einen Juror, wenn ein Tisch allein gelassen wird.';

  @override
  String webRenewal(String price) {
    return '$price im Jahr zuzüglich Steuern, verkauft von Link, einem verbundenen Unternehmen von Stripe, auf der Seite von Stripe. Das Abo verlängert sich jedes Jahr automatisch, bis du kündigst, zum dann geltenden Preis: Wir schreiben dir mindestens 7 Tage, bevor ein neuer Preis gelten würde. Kündige jederzeit unter Abo verwalten; Live-Spiel läuft bis zum Ende des bezahlten Jahres.';
  }

  @override
  String get subscribeAgrees =>
      'Mit dem Abo stimmst du den Nutzungsbedingungen zu.';

  @override
  String get accountSuspendedTitle => 'Vom Live-Spiel gesperrt';

  @override
  String get accountSuspended =>
      'Dieses Konto ist nach den Nutzungsbedingungen vom Live-Spiel gesperrt. Allein spielen kannst du weiterhin. Um zu fragen, warum, oder um Einspruch einzulegen, schreib an help@openhearts.game.';

  @override
  String storeNotAnswered(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'google': 'Google Play hat noch nicht gesagt, was Live-Spiel kostet. Prüf, ob du online bist, und tippe dann auf Abonnieren, um noch einmal zu fragen.',
      'other': 'Der App Store hat noch nicht gesagt, was Live-Spiel kostet. Prüf, ob du online bist, und tippe dann auf Abonnieren, um noch einmal zu fragen.',
    });
    return '$_temp0';
  }

  @override
  String get subscriptionIsYours =>
      'Ein Abo ist dein Konto, nicht das eines Geräts, und gespielt wird auf einem Gerät zur Zeit. Füge ein weiteres hinzu, indem du ihm diesen Code zeigst — es braucht nur seine Kamera — und entferne eines, wann du willst.';

  @override
  String get yourDevices => 'Deine Geräte';

  @override
  String devicesOf(int count, int most) {
    return '$count von $most';
  }

  @override
  String get addDevice => 'Gerät hinzufügen';

  @override
  String get pointTheCamera =>
      'Richte die Kamera des anderen Geräts hierauf. Der Code gilt zehn Minuten und für ein Gerät: Ein Foto dieses Bildschirms ist morgen nichts mehr wert.';

  @override
  String get sendLinkInstead => 'Stattdessen den Link schicken';

  @override
  String get thisDevice => 'Dieses Gerät';

  @override
  String deviceSince(String day) {
    return 'seit $day';
  }

  @override
  String get dropThisOne => 'Dieses entfernen';

  @override
  String get drop => 'Entfernen';

  @override
  String get codeToScan => 'Ein Code zum Scannen';

  @override
  String get notAPicture => 'Das ließ sich nicht als Bild lesen.';

  @override
  String couldNotOpen(String error) {
    return 'Konnte das nicht öffnen: $error';
  }

  @override
  String get done => 'Fertig';

  @override
  String get yourName => 'Dein Name';

  @override
  String get nameNotAllowed =>
      'Dieser Name ist nicht erlaubt. Wähl einen anderen.';

  @override
  String get howYouLook => 'Dein Aussehen';

  @override
  String colourNumber(int number) {
    return 'Farbe $number';
  }

  @override
  String get useAPhoto => 'Foto verwenden';

  @override
  String get myInitials => 'Meine Initialen';

  @override
  String avatarIcon(String icon) {
    String _temp0 = intl.Intl.selectLogic(icon, {
      'pets': 'Pfote',
      'rabbit': 'Hase',
      'bug': 'Käfer',
      'sailing': 'Segelboot',
      'rocket': 'Rakete',
      'anchor': 'Anker',
      'castle': 'Burg',
      'diamond': 'Diamant',
      'spa': 'Blatt',
      'park': 'Baum',
      'star': 'Stern',
      'bolt': 'Blitz',
      'sun': 'Sonne',
      'moon': 'Mond',
      'flower': 'Blume',
      'cake': 'Kuchen',
      'coffee': 'Kaffee',
      'music': 'Musiknote',
      'game': 'Controller',
      'umbrella': 'Regenschirm',
      'bike': 'Fahrrad',
      'piano': 'Klavier',
      'palette': 'Palette',
      'other': 'Schneeflocke',
    });
    return '$_temp0';
  }

  @override
  String paceKnown(String pace, int seconds) {
    String _temp0 = intl.Intl.selectLogic(pace, {
      'brisk': 'zügigem',
      'steady': 'gleichmäßigem',
      'unhurried': 'gemächlichem',
      'slow': 'langsamem',
      'other': 'noch unbekanntem',
    });
    String _temp1 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds Sekunden',
      one: '1 Sekunde',
    );
    return 'Du spielst in $_temp0 Tempo, etwa $_temp1 pro Karte, und sitzt mit Leuten in ähnlichem Tempo am Tisch';
  }

  @override
  String get paceUnknown =>
      'Dein Tempo ist noch nicht bekannt. Nach ein, zwei Live-Spielen sitzt du mit Leuten in ähnlichem Tempo am Tisch';

  @override
  String get rating => 'Wertung';

  @override
  String get countingGames => 'Zähle deine Spiele…';

  @override
  String get relaysSilent =>
      'Die Relays haben nicht geantwortet, darum kann sie gerade nicht angezeigt werden';

  @override
  String get playRatedForRating =>
      'Spiel ein gewertetes Live-Spiel, dann hast du eine';

  @override
  String ratingProvisionalFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Vorläufig, aus $games Spielen',
      one: 'Vorläufig, aus einem Spiel',
    );
    return '$_temp0';
  }

  @override
  String ratingFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Aus $games Spielen',
      one: 'Aus einem Spiel',
    );
    return '$_temp0';
  }

  @override
  String get yourGames => 'Deine Spiele';

  @override
  String get gamesLive => 'Live';

  @override
  String get gamesAlone => 'Allein';

  @override
  String get gamesPlayed => 'gespielt';

  @override
  String get gamesWon => 'gewonnen';

  @override
  String get gamesAverage => 'Schnitt';

  @override
  String get gamesBest => 'bestes';

  @override
  String get yourPicture => 'Dein Bild';

  @override
  String get useIt => 'Verwenden';

  @override
  String get cropHelp =>
      'Ziehen zum Verschieben, mit zwei Fingern vergrößern.\nWas im Kreis ist, ist dein Bild.';

  @override
  String get pictureFlagged =>
      'Dieses Gerät dachte, du würdest dieses Bild nicht am Tisch sehen wollen. Das ist eine Vermutung, hier getroffen, und sie kann falsch sein.';

  @override
  String showPicture(String name) {
    return 'Bild von $name zeigen';
  }

  @override
  String hidePicture(String name) {
    return 'Bild von $name ausblenden';
  }

  @override
  String get pictureChoiceNote =>
      'Nur auf diesem Gerät, und nur das Bild: Name und Punktestand bleiben.';

  @override
  String reportPlayer(String name) {
    return '$name melden';
  }

  @override
  String get reportWhat => 'Was ist los?';

  @override
  String get reportTheirPicture => 'Das Bild';

  @override
  String get reportTheirName => 'Der Name';

  @override
  String get reportSomethingElse => 'Etwas anderes';

  @override
  String get reportNoteHint => 'Was wir wissen sollten (optional)';

  @override
  String get reportGoesTo =>
      'Das geht nur an die Leute, die Open Hearts betreiben, mit der Nummer deines Kontos und der des gemeldeten Kontos.';

  @override
  String get reportSend => 'Senden';

  @override
  String get reportSent => 'Meldung gesendet. Danke.';

  @override
  String get reportTooMany => 'Mehr Meldungen kannst du heute nicht senden.';

  @override
  String get reportFailed =>
      'Die Meldung ist nicht angekommen. Versuch es noch einmal oder schreib an help@openhearts.game.';

  @override
  String blockPlayer(String name) {
    return '$name blockieren';
  }

  @override
  String get unblockPlayer => 'Blockierung aufheben';

  @override
  String get blockedPlayer => 'Blockierte Person';

  @override
  String get blockNote =>
      'Nur auf diesem Gerät: Du siehst Namen, Bild und Reaktionen dieser Person nicht mehr. Sie erfährt davon nichts.';

  @override
  String get liveAgreeTitle => 'Bevor du live spielst';

  @override
  String get liveAgreeBody =>
      'Um live zu spielen, akzeptiere die Nutzungsbedingungen.';

  @override
  String get liveAgree => 'Akzeptieren';

  @override
  String get liveTooYoungTitle => 'Live spielen erst ab 13';

  @override
  String liveTooYoung(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'google': 'Laut Google Play bist du unter 13.',
      'other': 'Laut deinem Apple Account bist du unter 13.',
    });
    return '$_temp0 Allein spielen kann jeder, so viel du willst.';
  }

  @override
  String get liveAwaitingParentTitle => 'Warten auf Zustimmung';

  @override
  String get liveAwaitingParent =>
      'Google Play wartet darauf, dass ein Elternteil oder Erziehungsberechtigter Änderungen an Open Hearts zustimmt. Danach kannst du live spielen. Bis dahin kannst du allein spielen.';

  @override
  String get liveParentDeclinedTitle => 'Nicht zugestimmt';

  @override
  String get liveParentDeclined =>
      'Ein Elternteil oder Erziehungsberechtigter hat Änderungen an Open Hearts in Google Play nicht zugestimmt, deshalb ist Live-Spielen geschlossen. Allein spielen kannst du weiterhin.';

  @override
  String get liveAgeUnconfirmedTitle => 'Bestätige dein Alter';

  @override
  String get liveAgeUnconfirmed =>
      'Google Play braucht eine Bestätigung deines Alters, bevor du live spielen kannst. Das geht in der Play Store App. Bis dahin kannst du allein spielen.';

  @override
  String get changedBoth =>
      'Unsere Nutzungsbedingungen und Datenschutzerklärung haben sich geändert.';

  @override
  String get changedTerms => 'Unsere Nutzungsbedingungen haben sich geändert.';

  @override
  String get changedPrivacy => 'Unsere Datenschutzerklärung hat sich geändert.';

  @override
  String get whatChanged => 'Was neu ist';

  @override
  String get readInFull => 'Ganzen Text lesen';

  @override
  String get deleteAccount => 'Konto löschen';

  @override
  String get deleteAccountTitle => 'Dein Konto löschen?';

  @override
  String get deleteAccountBody =>
      'Das lässt sich nicht rückgängig machen. Dein Konto wird auf allen seinen Geräten gelöscht – sein Profil, seine Geräte, seine Backup-Codes und seine Anmeldung –, und dein Name verschwindet aus den Spielen, die du gespielt hast. Außerdem wird alles gelöscht, was Open Hearts auf diesem Gerät speichert.\n\nDas Live-Spiel endet sofort, und die restliche Zeit deines Abos verfällt. Ein Web-Abo wird gekündigt. Eines aus dem App Store oder von Google Play verlängert sich weiter, bis du es dort kündigst.\n\nWenn du nicht mehr zahlen, aber bis zum Ende deines Jahres weiterspielen willst, kündige stattdessen.';

  @override
  String get keepAccount => 'Konto behalten';

  @override
  String get accountDeleted => 'Dein Konto ist gelöscht';

  @override
  String get accountDeletedClose =>
      'Schließe Open Hearts und öffne es wieder, um neu anzufangen.';

  @override
  String get waitingToReconnect =>
      'Warte, bis die anderen wieder verbunden sind';

  @override
  String get connectionDown =>
      'Deine Verbindung ist unterbrochen — verbinde neu';

  @override
  String get askingTheJury => 'Frage die Jury';

  @override
  String get noJurorOnline =>
      'Niemand online für eine Jury — warte auf jemanden';

  @override
  String get waitingForTheJury => 'Warte auf die Jury';

  @override
  String get openingDepartedHand =>
      'Öffne die Hand eines Spielers, der gegangen ist';

  @override
  String get nobodyClaimsTwo =>
      'Niemand meldet die Kreuz 2 — das Austeilen hängt';

  @override
  String bootPlayer(String name) {
    return '$name rauswerfen';
  }

  @override
  String get cannotDealTitle => 'Dieses Gerät kann nicht austeilen';

  @override
  String get cannotDealLabel => 'Das Austeilen funktioniert hier nicht mehr';

  @override
  String cannotDealWhy(String reason) {
    return 'Darum hast du den Tisch verlassen, und die anderen spielen mit einem Bot auf deinem Platz weiter. Wenn du die Seite neu lädst, beginnt das Austeilen von vorn. ($reason)';
  }

  @override
  String get connectionFailure => 'Verbindungsfehler';

  @override
  String get jurorQuorumLost => 'Zu wenige Juroren';

  @override
  String get jurorQuorumLostWhy =>
      'Zu wenige der Juroren, die die Bot-Plätze halten, sind noch online, darum kann die Runde nicht weitergehen. Das Spiel endet hier ohne Wertung.';

  @override
  String get onWithIt => 'Weiter';

  @override
  String get home => 'Start';

  @override
  String hereCount(int here, int humans, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'gewertet',
      'other': 'ungewertet',
    });
    return '$here von $humans da  ·  $_temp0';
  }

  @override
  String get botTookYourSeat => 'Ein Bot hat deinen Platz übernommen';

  @override
  String get tableCouldNotHear =>
      'Der Tisch hat nichts mehr von dir gehört und ohne dich weitergespielt.';

  @override
  String get back => 'Zurück';

  @override
  String get waitingForJurors => 'Warte auf die Jury…';

  @override
  String get dealing => 'Teile aus';

  @override
  String get dealingKeys => 'Teile aus — Schlüssel';

  @override
  String shuffling(int turn) {
    return 'Mische ($turn von 4)';
  }

  @override
  String get dealingTheCards => 'Teile die Karten aus';

  @override
  String get openingTheCards => 'Decke die Karten auf';

  @override
  String get gameEndsAt => 'Das Spiel endet, wenn jemand erreicht';

  @override
  String targetPoints(int target) {
    return '$target Punkte';
  }

  @override
  String get ratedMovesRatings =>
      'Gewertete Spiele verändern deine Wertung, und die der Bots';

  @override
  String get rated => 'Gewertet';

  @override
  String get unrated => 'Ungewertet';

  @override
  String get sourceCode => 'Code';

  @override
  String get licenseName => 'Lizenz';

  @override
  String get build => 'Version';

  @override
  String get published => 'Veröffentlicht';

  @override
  String get newBuildAvailable => 'Neue Version verfügbar';

  @override
  String get livePaused =>
      'Live-Spiel ist gerade pausiert. Allein spielen geht weiter.';

  @override
  String get updateDueWeb =>
      'Diese Version ist veraltet. Lade neu, um die neue zu bekommen.';

  @override
  String get updateDueApp =>
      'Diese Version ist veraltet. Aktualisiere die App, um die neue zu bekommen.';

  @override
  String get reload => 'Neu laden';

  @override
  String get tellUsWhatsBroken => 'Sag uns, was kaputt ist';

  @override
  String get feedbackIntro =>
      'Was ist passiert, und was hast du erwartet? Ein, zwei Sätze reichen.';

  @override
  String get feedbackHint => 'Was ist passiert';

  @override
  String get feedbackWithRecord =>
      'Auch das Protokoll dieses Spiels senden, damit die Runde nachgespielt werden kann';

  @override
  String get feedbackSentWithIt => 'Wird mitgeschickt';

  @override
  String get feedbackSend => 'Senden';

  @override
  String get feedbackIsPublic =>
      'Das öffnet ein Issue auf GitHub, das jeder lesen kann. Lass alles Private weg.';

  @override
  String get feedbackCopied => 'Kopiert. Füge es auf der geöffneten Seite ein.';

  @override
  String feedbackCopiedTo(String to) {
    return 'Kopiert. Füge es hier ein: $to';
  }

  @override
  String statsRecent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Deine letzten $count Spiele allein',
      one: 'Dein letztes Spiel allein',
    );
    return '$_temp0';
  }

  @override
  String statsRecentSpoken(int count, String scores, int average) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Endstände deiner letzten $count Spiele allein, ältestes zuerst: $scores. Schnitt $average.',
      one: 'Endstand deines letzten Spiels allein: $scores. Schnitt $average.',
    );
    return '$_temp0';
  }

  @override
  String statsAverage(int average) {
    return 'Schnitt $average';
  }

  @override
  String get statsLowerIsBetter =>
      'Endstände, ältestes zuerst. Weniger ist besser.';

  @override
  String get statsQueens => 'Pik-Dame genommen';

  @override
  String get statsMoonsShot => 'Durchmärsche';

  @override
  String get statsMoonsBlocked => 'Durchmärsche verhindert';

  @override
  String statsOverHands(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'In $hands Runden allein',
      one: 'In 1 Runde allein',
    );
    return '$_temp0';
  }

  @override
  String seatWhere(String where) {
    String _temp0 = intl.Intl.selectLogic(where, {
      'left': 'links von dir',
      'across': 'dir gegenüber',
      'other': 'rechts von dir',
    });
    return ', $_temp0';
  }

  @override
  String takesPoints(String who, int points) {
    String _temp0 = intl.Intl.pluralLogic(
      points,
      locale: localeName,
      other: '$points Punkte',
      one: '1 Punkt',
    );
    return '$who, $_temp0';
  }

  @override
  String sheetRow(String name, int delta, int total) {
    return '$name: $delta in dieser Runde, $total im Spiel';
  }

  @override
  String get joinHouseholdTitle => 'Diesem Abo beitreten?';

  @override
  String get joinHouseholdBody =>
      'Dieser Link fügt dieses Gerät einem Live-Spiel-Abo hinzu. Tritt nur bei, wenn er von dir stammt oder von jemandem, mit dem du teilst.';

  @override
  String get join => 'Beitreten';

  @override
  String get notNow => 'Nicht jetzt';

  @override
  String get privacyPolicy => 'Datenschutzerklärung';

  @override
  String get termsOfUse => 'Nutzungsbedingungen';

  @override
  String get manageSubscription => 'Abo verwalten';

  @override
  String get manageSubscriptionHint =>
      'Kündigen, Karte ändern oder Belege ansehen.';

  @override
  String get managedWhereBought =>
      'Dieses Abo wird dort verwaltet, wo es gekauft wurde.';

  @override
  String get licenceNotForThisDevice =>
      'Die Antwort des Dienstes war keine Lizenz für dieses Gerät.';

  @override
  String get storeFailed =>
      'Der Store hat den Kauf nicht abgeschlossen. Versuch es gleich noch einmal.';

  @override
  String get nothingToRestore =>
      'In diesem Store-Konto wurde kein Abo zum Wiederherstellen gefunden.';

  @override
  String get restorePurchases => 'Käufe wiederherstellen';

  @override
  String get storePending =>
      'Der Store wartet noch auf die Freigabe der Zahlung. Sobald sie da ist, ist Live-Spiel hier offen.';

  @override
  String storeRenewal(String price, String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'Apple-Konto',
      'other': 'Google-Konto',
    });
    String _temp1 = intl.Intl.selectLogic(store, {
      'apple': 'Apple',
      'other': 'Google',
    });
    String _temp2 = intl.Intl.selectLogic(store, {
      'apple': 'des App Store',
      'other': 'von Google Play',
    });
    return '$price im Jahr, abgebucht über dein $_temp0, wenn du bestätigst. Das Abo verlängert sich jedes Jahr automatisch, bis du kündigst, zum dann geltenden Preis, und $_temp1 informiert dich, bevor ein neuer Preis gilt. Kündige jederzeit in den Abo-Einstellungen $_temp2, spätestens einen Tag vor der Verlängerung.';
  }

  @override
  String manageInStore(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'im App Store',
      'other': 'bei Google Play',
    });
    return 'Kündigen oder ändern $_temp0.';
  }

  @override
  String get subscription => 'Abo';

  @override
  String get finishingPurchase => 'Kauf wird abgeschlossen …';

  @override
  String get paidLiveSoon =>
      'Deine Zahlung ist durch. Live-Spiel öffnet sich, sobald sie bei uns ankommt – lade in einer Minute neu.';

  @override
  String get activateSubscription => 'Abo aktivieren';

  @override
  String get activateBody =>
      'Hol dieses Gerät in ein Abo, das du schon hast. Scanne den Code, den ein anderes deiner Geräte unter Abo zeigt, oder tippe oder füge einen Code ein: diesen oder einen Backup-Code aus der E-Mail.';

  @override
  String get code => 'Code';

  @override
  String get paste => 'Einfügen';

  @override
  String get pasteByHand =>
      'Die Zwischenablage ließ sich hier nicht lesen. Halte das Codefeld gedrückt und wähle Einfügen.';

  @override
  String get scanCode => 'Code scannen';

  @override
  String get activate => 'Aktivieren';

  @override
  String get activated => 'Live-Spiel ist auf diesem Gerät offen.';

  @override
  String get noCamera =>
      'Hier gibt es keine Kamera zum Scannen. Tippe oder füge den Code stattdessen ein.';

  @override
  String get pointAtCode =>
      'Richte die Kamera auf den Code auf deinem anderen Gerät.';

  @override
  String get orTypeCode =>
      'Oder tippe diesen Code auf dem anderen Gerät unter Abo aktivieren ein:';

  @override
  String get copy => 'Kopieren';

  @override
  String get copied => 'Kopiert';

  @override
  String get backupCodes => 'Backup-Codes';

  @override
  String get backupCodesHint =>
      'Für den Tag, an dem keines deiner Geräte zur Hand ist, um einen Code zu zeigen. Jeder holt ein Gerät in dieses Abo, einmal. Bewahre sie sicher auf.';

  @override
  String get showBackupCodes => 'Backup-Codes zeigen';

  @override
  String get codeUsedMark => 'benutzt';

  @override
  String get replaceCodes => 'Codes ersetzen';

  @override
  String get replaceCodesTitle => 'Backup-Codes ersetzen?';

  @override
  String get replaceCodesBody =>
      'Diese fünf funktionieren nicht mehr, und fünf neue treten an ihre Stelle.';

  @override
  String get replace => 'Ersetzen';

  @override
  String get codesMade => 'Neue Codes erstellt.';

  @override
  String get emailCodes => 'Per E-Mail';

  @override
  String get codesSent => 'An die E-Mail-Adresse deines Abos gesendet.';

  @override
  String get codesNoAddress =>
      'Für dieses Abo gibt es keine E-Mail-Adresse, an die sie gehen könnten.';

  @override
  String get codesNotSent =>
      'Gerade konnten sie nicht gesendet werden. Versuch es später noch einmal.';

  @override
  String get haveACode => 'Hast du einen Code? Aktivieren';

  @override
  String get privacyShort => 'Datenschutz';

  @override
  String get termsShort => 'Bedingungen';

  @override
  String get gameTitle => 'Die Partie';

  @override
  String get checkingGame => 'Jede Karte des Spiels wird geprüft.';

  @override
  String get stillCheckingGame => 'Der Rest des Spiels wird geprüft …';

  @override
  String get noGameHere =>
      'Unter dieser Adresse ist keine beendete Partie gespeichert.';

  @override
  String gameDoesNotCheck(String reason) {
    return 'Das Protokoll dieser Partie ist nicht stimmig: $reason';
  }

  @override
  String get cantCheckGame =>
      'Dieses Gerät kann das Geben nicht prüfen und die Partie daher nicht zeigen.';

  @override
  String trickNumber(int trick) {
    return 'Stich $trick';
  }

  @override
  String seatPlayer(int seat) {
    return 'Spieler $seat';
  }

  @override
  String get seeWholeGame => 'Die ganze Partie ansehen';

  @override
  String get shareToWatch => 'Link zum Zuschauen teilen';

  @override
  String get liveNow => 'Live';

  @override
  String get watchingNote =>
      'Die Karten bleiben verdeckt, bis das Spiel vorbei ist; dann steht hier das ganze Spiel, geprüft.';

  @override
  String get passingNow => 'Karten werden weitergegeben';

  @override
  String get dealingNow => 'Es wird gegeben';

  @override
  String toPlayNow(String name) {
    return '$name ist am Zug';
  }

  @override
  String get yourAccount => 'Dein Konto';

  @override
  String get signInToKeep =>
      'Melde dich an, und ein neues Handy oder ein Browser, der dieses Gerät vergessen hat, kommt in dieses Konto zurück, wenn du dich dort genauso anmeldest. Von der Anmeldung wird nur eine unkenntlich gemachte Form ihrer Nummer aufbewahrt: kein Name, keine E-Mail.';

  @override
  String get signInToBringBack =>
      'Schon ein Abo, und auf deinem anderen Gerät angemeldet? Melde dich genauso an, um dieses Gerät in dein Konto zu holen.';

  @override
  String signedInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Mit Apple angemeldet.',
      'other': 'Mit Google angemeldet.',
    });
    return '$_temp0 Melde dich auf einem neuen Handy oder in einem anderen Browser genauso an, und dieses Abo kommt mit.';
  }

  @override
  String signedInBeforeBuying(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Mit Apple angemeldet.',
      'other': 'Mit Google angemeldet.',
    });
    return '$_temp0 Ein hier gekauftes Abo bleibt bei deinem Konto.';
  }

  @override
  String signInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Mit Apple anmelden',
      'other': 'Mit Google anmelden',
    });
    return '$_temp0';
  }

  @override
  String get accountElsewhere =>
      'Diese Anmeldung ist mit einem anderen Open-Hearts-Konto verknüpft. Dieses Konto auf diesem Gerät nutzen? Das Gerät verlässt dann das Konto, in dem es jetzt ist.';

  @override
  String get moveAccountHere => 'Dieses Konto hier nutzen';

  @override
  String get signedIn => 'Angemeldet.';

  @override
  String get signedInNoSubscription =>
      'Angemeldet. Mit dieser Anmeldung ist noch kein Konto verknüpft: Schließ ein Abo ab und melde dich dann auf der Abo-Seite an.';

  @override
  String get signInFailed =>
      'Die Anmeldung wurde nicht abgeschlossen. Versuch es gleich noch einmal.';

  @override
  String get openElsewhereTitle =>
      'Open Hearts ist jetzt auf einem anderen Gerät offen';

  @override
  String get openElsewhereBody =>
      'Dein Konto spielt auf einem Gerät zur Zeit, und das zuletzt geöffnete gilt. Dieses ist zurückgetreten: weg vom Tisch, aus der Jury und aus der Warteschlange. Nutze es hier, dann tritt das andere zurück.';

  @override
  String get inGameElsewhereTitle =>
      'Du bist in einer Partie auf einem anderen Gerät';

  @override
  String get inGameElsewhereBody =>
      'Hier weitermachen? Diese Partie geht dann verloren.';

  @override
  String get continueHere => 'Hier weitermachen';

  @override
  String get useItHere => 'Hier nutzen';

  @override
  String get liveOpenElsewhere =>
      'Dein Konto wird auf einem anderen Gerät genutzt.';

  @override
  String get deviceInUse => 'in Gebrauch';

  @override
  String get reviewIsLivePlay =>
      'Einer Partie zuschauen und eine gespielte ansehen gehört zum Live-Spiel.';

  @override
  String get reviewOwnGame =>
      'Das ist deine eigene Partie, sie läuft noch. Sie ist hier, sobald sie vorbei ist.';

  @override
  String get autoSwitch => 'Auto';

  @override
  String get autoPlayLabel => 'Den Rest dieser Runde automatisch spielen';

  @override
  String get autoOffered =>
      'An dieser Runde kann keine deiner Karten mehr etwas ändern. Auto spielt sie für dich zu Ende.';

  @override
  String reaction(String code) {
    String _temp0 = intl.Intl.selectLogic(code, {
      'nice': 'Stark',
      'ha': 'Haha',
      'wow': 'Wow',
      'ouch': 'Autsch',
      'sorry': 'Sorry',
      'gg': 'Gutes Spiel',
      'other': '…',
    });
    return '$_temp0';
  }

  @override
  String reactionSaid(String name, String reaction) {
    return '$name: $reaction';
  }

  @override
  String get react => 'Reagieren';

  @override
  String get hideReactions => 'Reaktionen der anderen ausblenden';
}
