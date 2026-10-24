// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String cardName(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'valet',
      'queen': 'dame',
      'king': 'roi',
      'ace': 'as',
      'other': '$number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'trèfle',
      'diamonds': 'carreau',
      'spades': 'pique',
      'other': 'cœur',
    });
    return '$_temp0 de $_temp1';
  }

  @override
  String cardWithArticle(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'le valet',
      'queen': 'la dame',
      'king': 'le roi',
      'ace': 'l\'as',
      'other': 'le $number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'trèfle',
      'diamonds': 'carreau',
      'spades': 'pique',
      'other': 'cœur',
    });
    return '$_temp0 de $_temp1';
  }

  @override
  String seatLed(String name, String card) {
    return '$name a entamé avec $card';
  }

  @override
  String seatPlayed(String name, String card) {
    return '$name a joué $card';
  }

  @override
  String passDirection(String direction) {
    String _temp0 = intl.Intl.selectLogic(direction, {
      'left': 'Passe à gauche',
      'right': 'Passe à droite',
      'across': 'Passe en face',
      'other': 'Pas de passe',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstLead => 'Le 2 de trèfle entame le premier pli';

  @override
  String refuseFollowSuit(String suit) {
    String _temp0 = intl.Intl.selectLogic(suit, {
      'clubs': 'Vous devez jouer trèfle',
      'diamonds': 'Vous devez jouer carreau',
      'spades': 'Vous devez jouer pique',
      'other': 'Vous devez jouer cœur',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstTrickPoints => 'Pas de points au premier pli';

  @override
  String get refuseHeartsUnbroken => 'Les cœurs ne sont pas encore ouverts';

  @override
  String get refuseOther => 'Vous ne pouvez pas jouer cette carte';

  @override
  String get you => 'Vous';

  @override
  String seatNumber(int seat) {
    return 'Place $seat';
  }

  @override
  String handHeader(int hand, String pass, int target) {
    return 'Donne $hand  ·  $pass  ·  en $target';
  }

  @override
  String handHeaderShort(int hand, String pass) {
    return 'Donne $hand  ·  $pass';
  }

  @override
  String get heartsBroken => 'Les cœurs sont ouverts';

  @override
  String get heartsNotBroken => 'Les cœurs ne sont pas ouverts';

  @override
  String get menu => 'Menu';

  @override
  String get leaveTheTable => 'Quitter la table';

  @override
  String get about => 'À propos';

  @override
  String get language => 'Langue';

  @override
  String get deviceLanguage => 'Celle de l\'appareil';

  @override
  String get recordCopied => 'Relevé copié';

  @override
  String choosePass(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Choisissez encore $count cartes à passer',
      one: 'Choisissez encore 1 carte à passer',
    );
    return '$_temp0';
  }

  @override
  String choosePassShort(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Encore $count à choisir',
      one: 'Encore 1 à choisir',
    );
    return '$_temp0';
  }

  @override
  String get passButton => 'Passer';

  @override
  String passedYou(String name) {
    return '$name vous a passé';
  }

  @override
  String passedTo(String name) {
    return 'Passées à $name';
  }

  @override
  String get waitingForOthers => 'En attente des autres';

  @override
  String seatScores(String name, int total, int taken) {
    return '$name : $total dans la partie, $taken dans cette donne';
  }

  @override
  String get seatOnTurn => ', à son tour';

  @override
  String seatClock(int seconds) {
    return ', $seconds s au chrono';
  }

  @override
  String get youTakeIt => 'Vous prenez le pli';

  @override
  String takesIt(String name) {
    return '$name prend le pli';
  }

  @override
  String get yourTurn => 'À vous';

  @override
  String get whatHasGone => 'Déjà joué';

  @override
  String stillOut(int hearts, String queen) {
    String _temp0 = intl.Intl.pluralLogic(
      hearts,
      locale: localeName,
      other: '$hearts cœurs',
      one: '1 cœur',
      zero: 'Aucun cœur',
    );
    String _temp1 = intl.Intl.selectLogic(queen, {
      'true': ' et la dame',
      'other': '',
    });
    return '$_temp0$_temp1 encore en jeu';
  }

  @override
  String get nextHand => 'Donne suivante';

  @override
  String get newGame => 'Nouvelle partie';

  @override
  String get playAgain => 'Rejouer';

  @override
  String handNumber(int hand) {
    return 'Donne $hand';
  }

  @override
  String get youShotTheMoon => 'Vous avez fait le grand chelem';

  @override
  String shotTheMoon(String name) {
    return '$name a fait le grand chelem';
  }

  @override
  String get shotTheMoonDetail => 'Les 26 — pour tous les autres';

  @override
  String get aShareOfIt => 'Victoire partagée';

  @override
  String get youWin => 'Vous gagnez';

  @override
  String namesTie(String names) {
    return 'Égalité : $names';
  }

  @override
  String get listAnd => 'et';

  @override
  String nameWins(String name) {
    return '$name gagne';
  }

  @override
  String lowestScoreAfter(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Le score le plus bas après $hands donnes',
      one: 'Le score le plus bas après 1 donne',
    );
    return '$_temp0';
  }

  @override
  String get copyRecord => 'Copier le relevé';

  @override
  String ratingNow(String rating) {
    return 'Classement $rating';
  }

  @override
  String ratingMoved(String before, String after) {
    return 'Classement $before → $after';
  }

  @override
  String get tagline => 'Jeu de cartes open source, sans pub';

  @override
  String get playSolo => 'Jouer seul';

  @override
  String get stillLookingForRelay => 'Recherche d\'un relais…';

  @override
  String noRelayTakesEvents(String reason) {
    return 'Aucun relais n\'accepte les messages de cet appareil : $reason';
  }

  @override
  String couldNotConnect(String error) {
    return 'Connexion impossible : $error';
  }

  @override
  String get noRelayAnswered =>
      'Aucun relais n\'a répondu. Vérifiez la connexion et réessayez.';

  @override
  String get tableFilledWithoutYou => 'Cette table s\'est remplie sans vous';

  @override
  String get linkCopied => 'Lien copié';

  @override
  String get livePlay => 'Jeu en direct';

  @override
  String get yourProfile => 'Votre profil';

  @override
  String get gameOptions => 'Options de partie';

  @override
  String gameLine(int target, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'classée',
      'other': 'non classée',
    });
    return '$target points · $_temp0';
  }

  @override
  String youAreRated(int rating, String provisional, int games) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisoire',
      'other': '',
    });
    String _temp1 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'sur $games parties classées',
      one: 'sur 1 partie classée',
    );
    return 'Votre classement est de $rating$_temp0, $_temp1.';
  }

  @override
  String get playLive => 'Jouer en direct';

  @override
  String playLiveSpoken(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: 'Jouer en direct, $online en ligne',
      one: 'Jouer en direct, personne d\'autre en ligne',
      zero: 'Jouer en direct, personne d\'autre en ligne',
    );
    return '$_temp0';
  }

  @override
  String onlineCount(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online en ligne',
      one: 'Personne d\'autre en ligne',
      zero: 'Personne d\'autre en ligne',
    );
    return '$_temp0';
  }

  @override
  String get playFriends => 'Jouer entre amis';

  @override
  String pricePerYear(String amount) {
    return '$amount par an';
  }

  @override
  String get seatsOrFriends =>
      'Quatre places, pour ceux qui attendent — ou un lien que vous envoyez à trois amis.';

  @override
  String get subscribe => 'S\'abonner';

  @override
  String get aloneIsFree =>
      'Jouer seul est gratuit, et nous n\'avons pas l\'intention de changer cela.';

  @override
  String get findingPlayers => 'Recherche de joueurs';

  @override
  String waitedLine(int seconds, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', $others autres en attente',
      one: ', 1 autre en attente',
      zero: '',
    );
    return '$seconds s$_temp0 — des bots prennent les places vides à dix';
  }

  @override
  String get playNowWithBots => 'Jouer maintenant avec des bots';

  @override
  String get waitForPerson => 'Attendre une personne';

  @override
  String get waitForPersonHint =>
      'Jusqu\'à cinq minutes. Nous sommes prévenus que quelqu\'un attend, et viendrons peut-être jouer.';

  @override
  String get waitingForPerson => 'En attente d\'une personne';

  @override
  String waitingForPersonLine(String waited, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', $others autres en attente',
      one: ', 1 autre en attente',
      zero: '',
    );
    return '$waited sur 5:00$_temp0 — ensuite des bots prennent les places vides';
  }

  @override
  String get seatingWithBots => 'Installation avec des bots';

  @override
  String get cancel => 'Annuler';

  @override
  String get roomSendLink =>
      'Envoyez le lien. La partie commence dix secondes après l\'arrivée de quelqu\'un.';

  @override
  String roomStartingIn(int seconds) {
    return 'Début dans $seconds s — les places vides vont aux bots';
  }

  @override
  String get shareTheLink => 'Partager le lien';

  @override
  String nameIsYou(String name) {
    return '$name (vous)';
  }

  @override
  String get emptySeat => 'un bot, sauf si quelqu\'un arrive';

  @override
  String get startNow => 'Commencer';

  @override
  String get leave => 'Partir';

  @override
  String ratedSpoken(int rating, String provisional) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisoire',
      'other': '',
    });
    return 'classement $rating$_temp0';
  }

  @override
  String get roomOtherBuild =>
      'L\'application de quelqu\'un n\'est pas à la même version que la vôtre — l\'une des deux est plus ancienne. Mettez à jour et réessayez.';

  @override
  String get noDealPageStopped =>
      'La donne qui garantit des cartes honnêtes ne fonctionne plus sur cette page. Rechargez-la pour repartir de zéro.';

  @override
  String get noDealAppStopped =>
      'La donne qui garantit des cartes honnêtes ne fonctionne plus. Redémarrez l\'application pour repartir de zéro.';

  @override
  String get noDealBrowser =>
      'Ce navigateur ne peut pas exécuter la donne qui garantit des cartes honnêtes. Essayez un Chrome, Firefox ou Safari récent.';

  @override
  String get noDealBuild =>
      'Cette version ne peut pas exécuter la donne qui garantit des cartes honnêtes, et ne peut donc pas s\'asseoir à une table en direct.';

  @override
  String get serviceUnreachable =>
      'Impossible de joindre le service. Réessayez dans un instant.';

  @override
  String get codeNotForThisDevice => 'Ce code n\'est pas pour cet appareil.';

  @override
  String serviceRefusal(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noSubscription': 'Aucun abonnement.',
      'accountFull':
          'Cet abonnement a déjà tous les appareils qu\'il peut avoir.',
      'notACode': 'Ce n\'est pas un code.',
      'noSuchCode': 'Ce code n\'existe pas.',
      'codeUsed': 'Ce code a déjà servi.',
      'codeRunOut': 'Ce code a expiré.',
      'notADevice': 'Cet appareil ne fait pas partie de cet abonnement.',
      'onAnotherSubscription': 'Cet appareil fait partie d\'un autre abonnement. Retirez-le d\'abord de celui-ci.',
      'clockOff': 'L\'horloge de cet appareil n\'est pas à l\'heure. Réglez-la et réessayez.',
      'notAStore': 'Le service ne connaît pas cette boutique.',
      'noProof': 'La boutique n\'a fourni aucune preuve de l\'achat.',
      'notFromStore': 'Cet achat ne vient pas de la boutique.',
      'notPaid': 'D\'après la boutique, cet achat n\'est pas payé.',
      'storeNotAnswering':
          'La boutique ne répond pas. Réessayez dans un instant.',
      'storeNotSetUp': 'L\'achat dans la boutique n\'est pas encore ouvert.',
      'signInRefused': 'Cette connexion n\'a pas pu être vérifiée. Réessayez.',
      'accountElsewhere': 'Cette connexion est liée à un autre compte.',
      'accountNowhere': 'Aucun compte n\'est encore lié à cette connexion.',
      'otherSignIn': 'Ce compte est déjà lié à une autre connexion.',
      'signInNotSetUp': 'La connexion n\'est pas encore ouverte.',
      'other': 'Le service a refusé.',
    });
    return '$_temp0';
  }

  @override
  String get buyingNotOpen =>
      'L\'achat n\'est pas encore possible sur cet appareil.';

  @override
  String get shopUnreachable =>
      'Impossible de joindre la boutique. Réessayez dans un instant.';

  @override
  String get shopNotOpen => 'La boutique n\'est pas encore ouverte.';

  @override
  String openUntil(String day) {
    return 'Activé sur cet appareil jusqu\'au $day';
  }

  @override
  String get pointRating =>
      'Un classement à vous, issu de résultats que vous signez à quatre.';

  @override
  String get pointDeal =>
      'Les cartes sont distribuées entre vous quatre. Aucun serveur ne voit une main, pas même le nôtre.';

  @override
  String get whatMoneyPaysFor =>
      'Jouer seul est gratuit, tout comme les relevés, le moteur et chaque ligne de ce code, et nous n\'avons pas l\'intention de changer cela. L\'argent paie ce qui nous coûte à faire tourner : vous mettre en relation, un relais quand deux appareils ne trouvent pas de chemin direct, et un juré quand une table est laissée seule.';

  @override
  String webRenewal(String price) {
    return '$price par an plus les taxes applicables, vendu par Link, société affiliée à Stripe, sur la page de Stripe. L\'abonnement se renouvelle automatiquement chaque année jusqu\'à ce que vous le résiliiez, au prix alors en vigueur : nous vous écrivons au moins 7 jours avant qu\'un nouveau prix s\'applique. Résiliez quand vous voulez dans Gérer l\'abonnement ; le jeu en direct dure jusqu\'à la fin de l\'année payée.';
  }

  @override
  String get subscribeAgrees =>
      'En vous abonnant, vous acceptez les Conditions d\'utilisation.';

  @override
  String get accountSuspendedTitle => 'Suspendu du jeu en direct';

  @override
  String get accountSuspended =>
      'Ce compte est suspendu du jeu en direct en application des conditions d\'utilisation. Jouer seul reste possible. Pour savoir pourquoi, ou pour faire appel, écrivez à help@openhearts.game.';

  @override
  String storeNotAnswered(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'google': 'Google Play n\'a pas encore indiqué le prix du jeu en direct. Vérifiez que vous êtes connecté, puis touchez S\'abonner pour lui redemander.',
      'other': 'L\'App Store n\'a pas encore indiqué le prix du jeu en direct. Vérifiez que vous êtes connecté, puis touchez S\'abonner pour lui redemander.',
    });
    return '$_temp0';
  }

  @override
  String get subscriptionIsYours =>
      'Un abonnement est votre compte, pas celui d\'un appareil, et il se joue sur un appareil à la fois. Ajoutez-en un autre en lui montrant ce code — son appareil photo suffit — et retirez-en un quand vous voulez.';

  @override
  String get yourDevices => 'Vos appareils';

  @override
  String devicesOf(int count, int most) {
    return '$count sur $most';
  }

  @override
  String get addDevice => 'Ajouter un appareil';

  @override
  String get pointTheCamera =>
      'Pointez l\'appareil photo de l\'autre appareil vers ceci. Le code vaut dix minutes et pour un seul appareil : une photo de cet écran demain ne vaudra rien.';

  @override
  String get sendLinkInstead => 'Envoyer le lien à la place';

  @override
  String get thisDevice => 'Cet appareil';

  @override
  String deviceSince(String day) {
    return 'depuis le $day';
  }

  @override
  String get dropThisOne => 'Retirer celui-ci';

  @override
  String get drop => 'Retirer';

  @override
  String get codeToScan => 'Un code à scanner';

  @override
  String get notAPicture => 'Ce fichier n\'a pas pu être lu comme une image.';

  @override
  String couldNotOpen(String error) {
    return 'Impossible d\'ouvrir ce fichier : $error';
  }

  @override
  String get done => 'OK';

  @override
  String get yourName => 'Votre nom';

  @override
  String get nameNotAllowed =>
      'Ce nom n\'est pas autorisé. Choisissez-en un autre.';

  @override
  String get howYouLook => 'Votre apparence';

  @override
  String colourNumber(int number) {
    return 'Couleur $number';
  }

  @override
  String get useAPhoto => 'Utiliser une photo';

  @override
  String get myInitials => 'Mes initiales';

  @override
  String avatarIcon(String icon) {
    String _temp0 = intl.Intl.selectLogic(icon, {
      'pets': 'Patte',
      'rabbit': 'Lapin',
      'bug': 'Insecte',
      'sailing': 'Voilier',
      'rocket': 'Fusée',
      'anchor': 'Ancre',
      'castle': 'Château',
      'diamond': 'Diamant',
      'spa': 'Feuille',
      'park': 'Arbre',
      'star': 'Étoile',
      'bolt': 'Éclair',
      'sun': 'Soleil',
      'moon': 'Lune',
      'flower': 'Fleur',
      'cake': 'Gâteau',
      'coffee': 'Café',
      'music': 'Note de musique',
      'game': 'Manette',
      'umbrella': 'Parapluie',
      'bike': 'Vélo',
      'piano': 'Piano',
      'palette': 'Palette',
      'other': 'Flocon de neige',
    });
    return '$_temp0';
  }

  @override
  String paceKnown(String pace, int seconds) {
    String _temp0 = intl.Intl.selectLogic(pace, {
      'brisk': 'vif',
      'steady': 'régulier',
      'unhurried': 'posé',
      'slow': 'lent',
      'other': 'encore inconnu',
    });
    String _temp1 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds secondes',
      one: '1 seconde',
    );
    return 'Vous jouez à un rythme $_temp0, environ $_temp1 par carte, et êtes placé avec des joueurs au rythme semblable';
  }

  @override
  String get paceUnknown =>
      'Votre rythme n\'est pas encore connu. Après une ou deux parties en direct, vous serez placé avec des joueurs au rythme semblable';

  @override
  String get rating => 'Classement';

  @override
  String get countingGames => 'Comptage de vos parties…';

  @override
  String get relaysSilent =>
      'Les relais n\'ont pas répondu, il ne peut donc pas être affiché pour l\'instant';

  @override
  String get playRatedForRating =>
      'Jouez une partie classée en direct pour en avoir un';

  @override
  String ratingProvisionalFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Provisoire, sur $games parties',
      one: 'Provisoire, sur une partie',
    );
    return '$_temp0';
  }

  @override
  String ratingFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Sur $games parties',
      one: 'Sur une partie',
    );
    return '$_temp0';
  }

  @override
  String get yourGames => 'Vos parties';

  @override
  String get gamesLive => 'Direct';

  @override
  String get gamesAlone => 'Seul';

  @override
  String get gamesPlayed => 'jouées';

  @override
  String get gamesWon => 'gagnées';

  @override
  String get gamesAverage => 'moyenne';

  @override
  String get gamesBest => 'meilleure';

  @override
  String get yourPicture => 'Votre image';

  @override
  String get useIt => 'Utiliser';

  @override
  String get cropHelp =>
      'Faites glisser pour la déplacer, pincez pour l\'agrandir.\nCe qui est dans le cercle est votre image.';

  @override
  String get pictureFlagged =>
      'Cet appareil a pensé que vous ne voudriez pas de cette image à la table. C\'est une supposition, faite ici, et elle peut être fausse.';

  @override
  String showPicture(String name) {
    return 'Afficher l\'image de $name';
  }

  @override
  String hidePicture(String name) {
    return 'Masquer l\'image de $name';
  }

  @override
  String get pictureChoiceNote =>
      'Sur cet appareil seulement, et seulement l\'image : le nom et le score restent.';

  @override
  String reportPlayer(String name) {
    return 'Signaler $name';
  }

  @override
  String get reportWhat => 'Quel est le problème ?';

  @override
  String get reportTheirPicture => 'Son image';

  @override
  String get reportTheirName => 'Son nom';

  @override
  String get reportSomethingElse => 'Autre chose';

  @override
  String get reportNoteHint => 'Ce que nous devrions savoir (facultatif)';

  @override
  String get reportGoesTo =>
      'Ceci n\'est envoyé qu\'aux personnes qui gèrent Open Hearts, avec le numéro de votre compte et celui du compte signalé.';

  @override
  String get reportSend => 'Envoyer';

  @override
  String get reportSent => 'Signalement envoyé. Merci.';

  @override
  String get reportTooMany =>
      'Vous avez envoyé autant de signalements que possible aujourd\'hui.';

  @override
  String get reportFailed =>
      'Le signalement n\'est pas parti. Réessayez ou écrivez à help@openhearts.game.';

  @override
  String blockPlayer(String name) {
    return 'Bloquer $name';
  }

  @override
  String get unblockPlayer => 'Débloquer';

  @override
  String get blockedPlayer => 'Personne bloquée';

  @override
  String get blockNote =>
      'Sur cet appareil seulement : vous ne verrez plus son nom, son image ni ses réactions. Cette personne n\'en est pas avertie.';

  @override
  String get liveAgreeTitle => 'Avant de jouer en direct';

  @override
  String get liveAgreeBody =>
      'Pour jouer en direct, acceptez les Conditions d\'utilisation.';

  @override
  String get liveAgree => 'Accepter';

  @override
  String get liveTooYoungTitle => 'Le jeu en direct, c\'est à partir de 13 ans';

  @override
  String liveTooYoung(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'google': 'Selon Google Play, vous avez moins de 13 ans.',
      'other': 'Selon votre compte Apple, vous avez moins de 13 ans.',
    });
    return '$_temp0 Jouer seul est ouvert à tous, autant que vous voulez.';
  }

  @override
  String get liveAwaitingParentTitle => 'En attente d\'un parent';

  @override
  String get liveAwaitingParent =>
      'Google Play attend qu\'un parent ou un tuteur approuve des changements d\'Open Hearts. Le jeu en direct s\'ouvrira dès qu\'il l\'aura fait. En attendant, vous pouvez jouer seul.';

  @override
  String get liveParentDeclinedTitle => 'Non approuvé';

  @override
  String get liveParentDeclined =>
      'Un parent ou un tuteur n\'a pas approuvé des changements d\'Open Hearts dans Google Play : le jeu en direct est donc fermé. Vous pouvez toujours jouer seul.';

  @override
  String get liveAgeUnconfirmedTitle => 'Confirmez votre âge';

  @override
  String get liveAgeUnconfirmed =>
      'Google Play doit confirmer votre âge avant que vous puissiez jouer en direct. Vous pouvez le faire dans l\'app Play Store. En attendant, vous pouvez jouer seul.';

  @override
  String get changedBoth =>
      'Nos conditions d\'utilisation et notre politique de confidentialité ont changé.';

  @override
  String get changedTerms => 'Nos conditions d\'utilisation ont changé.';

  @override
  String get changedPrivacy => 'Notre politique de confidentialité a changé.';

  @override
  String get whatChanged => 'Ce qui change';

  @override
  String get readInFull => 'Lire le texte complet';

  @override
  String get deleteAccount => 'Supprimer le compte';

  @override
  String get deleteAccountTitle => 'Supprimer votre compte ?';

  @override
  String get deleteAccountBody =>
      'C\'est définitif. Votre compte est supprimé sur tous ses appareils — son profil, ses appareils, ses codes de secours et sa connexion — et votre nom est retiré des parties que vous avez jouées. Tout ce qu\'Open Hearts garde sur cet appareil est aussi effacé.\n\nLe jeu en direct s\'arrête maintenant, et le temps qui reste sur votre abonnement est perdu. Un abonnement pris sur le web est résilié. Un abonnement de l\'App Store ou de Google Play continue de se renouveler jusqu\'à ce que vous le résiliiez là-bas.\n\nPour ne plus payer mais continuer à jouer jusqu\'à la fin de votre année, résiliez plutôt l\'abonnement.';

  @override
  String get keepAccount => 'Garder le compte';

  @override
  String get accountDeleted => 'Votre compte est supprimé';

  @override
  String get accountDeletedClose =>
      'Fermez Open Hearts et rouvrez-le pour repartir de zéro.';

  @override
  String get waitingToReconnect => 'En attente de la reconnexion des autres';

  @override
  String get connectionDown => 'Votre connexion est coupée — reconnexion';

  @override
  String get askingTheJury => 'Consultation du jury';

  @override
  String get noJurorOnline =>
      'Personne en ligne pour former un jury — en attente';

  @override
  String get waitingForTheJury => 'En attente du jury';

  @override
  String get openingDepartedHand => 'Ouverture de la main d\'un joueur parti';

  @override
  String get nobodyClaimsTwo =>
      'Personne n\'annonce le 2♣ — la donne est bloquée';

  @override
  String bootPlayer(String name) {
    return 'Exclure $name';
  }

  @override
  String get cannotDealTitle => 'Cet appareil ne peut pas distribuer';

  @override
  String get cannotDealLabel => 'La donne a cessé de fonctionner ici';

  @override
  String cannotDealWhy(String reason) {
    return 'Vous avez donc quitté la table, et les autres continuent avec un bot à votre place. Recharger la page relance la donne. ($reason)';
  }

  @override
  String get connectionFailure => 'Échec de connexion';

  @override
  String get jurorQuorumLost => 'Quorum de jurés perdu';

  @override
  String get jurorQuorumLostWhy =>
      'Trop peu des jurés qui tiennent les places des bots sont encore en ligne, la donne ne peut donc pas continuer. La partie s\'arrête ici, sans être comptée.';

  @override
  String get onWithIt => 'Continuer';

  @override
  String get home => 'Accueil';

  @override
  String hereCount(int here, int humans, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'classée',
      'other': 'non classée',
    });
    return '$here sur $humans présents  ·  $_temp0';
  }

  @override
  String get botTookYourSeat => 'Un bot a pris votre place';

  @override
  String get tableCouldNotHear =>
      'La table n\'avait plus de nouvelles de vous, et a continué sans vous.';

  @override
  String get back => 'Retour';

  @override
  String get waitingForJurors => 'En attente du jury…';

  @override
  String get dealing => 'Distribution';

  @override
  String get dealingKeys => 'Distribution — clés';

  @override
  String shuffling(int turn) {
    return 'Mélange ($turn sur 4)';
  }

  @override
  String get dealingTheCards => 'Distribution des cartes';

  @override
  String get openingTheCards => 'Ouverture des cartes';

  @override
  String get gameEndsAt => 'La partie se termine quand quelqu\'un atteint';

  @override
  String targetPoints(int target) {
    return '$target points';
  }

  @override
  String get ratedMovesRatings =>
      'Les parties classées font bouger votre classement, et celui des bots';

  @override
  String get rated => 'Classée';

  @override
  String get unrated => 'Non classée';

  @override
  String get sourceCode => 'Code';

  @override
  String get licenseName => 'Licence';

  @override
  String get build => 'Version';

  @override
  String get published => 'Publiée';

  @override
  String get newBuildAvailable => 'Nouvelle version disponible';

  @override
  String get livePaused =>
      'Le jeu en direct est en pause pour l\'instant. Le jeu en solo reste ouvert.';

  @override
  String get updateDueWeb =>
      'Cette version n\'est plus à jour. Rechargez pour avoir la nouvelle.';

  @override
  String get updateDueApp =>
      'Cette version n\'est plus à jour. Mettez l\'application à jour pour avoir la nouvelle.';

  @override
  String get reload => 'Recharger';

  @override
  String get tellUsWhatsBroken => 'Signaler un problème';

  @override
  String get feedbackIntro =>
      'Que s\'est-il passé, et qu\'attendiez-vous ? Une phrase ou deux suffisent.';

  @override
  String get feedbackHint => 'Ce qui s\'est passé';

  @override
  String get feedbackWithRecord =>
      'Envoyer aussi le relevé de cette partie, pour pouvoir rejouer la donne';

  @override
  String get feedbackSentWithIt => 'Envoyé avec';

  @override
  String get feedbackSend => 'Envoyer';

  @override
  String get feedbackIsPublic =>
      'Ceci ouvre un ticket sur GitHub, que tout le monde peut lire. N\'y mettez rien de privé.';

  @override
  String get feedbackCopied =>
      'Copié. Collez-le dans la page qui s\'est ouverte.';

  @override
  String feedbackCopiedTo(String to) {
    return 'Copié. Collez-le ici : $to';
  }

  @override
  String statsRecent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Vos $count dernières parties en solo',
      one: 'Votre dernière partie en solo',
    );
    return '$_temp0';
  }

  @override
  String statsRecentSpoken(int count, String scores, int average) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Scores finaux de vos $count dernières parties en solo, de la plus ancienne à la plus récente : $scores. Moyenne $average.',
      one:
          'Score final de votre dernière partie en solo : $scores. Moyenne $average.',
    );
    return '$_temp0';
  }

  @override
  String statsAverage(int average) {
    return 'moyenne $average';
  }

  @override
  String get statsLowerIsBetter =>
      'Scores finaux, du plus ancien au plus récent. Plus c\'est bas, mieux c\'est.';

  @override
  String get statsQueens => 'Dame de pique prise';

  @override
  String get statsMoonsShot => 'Grands chelems';

  @override
  String get statsMoonsBlocked => 'Grands chelems bloqués';

  @override
  String statsOverHands(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Sur $hands donnes en solo',
      one: 'Sur 1 donne en solo',
    );
    return '$_temp0';
  }

  @override
  String seatWhere(String where) {
    String _temp0 = intl.Intl.selectLogic(where, {
      'left': 'à votre gauche',
      'across': 'en face de vous',
      'other': 'à votre droite',
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
    return '$name : $delta dans cette donne, $total dans la partie';
  }

  @override
  String get joinHouseholdTitle => 'Rejoindre cet abonnement ?';

  @override
  String get joinHouseholdBody =>
      'Ce lien ajoute cet appareil à un abonnement de jeu en direct. Ne le rejoignez que s\'il vient de vous ou d\'une personne avec qui vous le partagez.';

  @override
  String get join => 'Rejoindre';

  @override
  String get notNow => 'Pas maintenant';

  @override
  String get privacyPolicy => 'Politique de confidentialité';

  @override
  String get termsOfUse => 'Conditions d\'utilisation';

  @override
  String get manageSubscription => 'Gérer l\'abonnement';

  @override
  String get manageSubscriptionHint =>
      'Résiliez, changez de carte ou consultez les reçus.';

  @override
  String get managedWhereBought =>
      'Cet abonnement se gère là où il a été acheté.';

  @override
  String get licenceNotForThisDevice =>
      'La réponse du service n\'était pas une licence pour cet appareil.';

  @override
  String get storeFailed =>
      'La boutique n\'a pas terminé l\'achat. Réessayez dans un instant.';

  @override
  String get nothingToRestore =>
      'Aucun abonnement à restaurer n\'a été trouvé sur ce compte de la boutique.';

  @override
  String get restorePurchases => 'Restaurer les achats';

  @override
  String get storePending =>
      'La boutique attend d\'approuver le paiement. Le jeu en direct s\'ouvrira ici dès que ce sera fait.';

  @override
  String storeRenewal(String price, String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'compte Apple',
      'other': 'compte Google',
    });
    String _temp1 = intl.Intl.selectLogic(store, {
      'apple': 'Apple',
      'other': 'Google',
    });
    String _temp2 = intl.Intl.selectLogic(store, {
      'apple': 'de l\'App Store',
      'other': 'de Google Play',
    });
    return '$price par an, débité sur votre $_temp0 à la confirmation. L\'abonnement se renouvelle automatiquement chaque année jusqu\'à ce que vous le résiliiez, au prix alors en vigueur, et $_temp1 vous prévient avant qu\'un nouveau prix s\'applique. Résiliez quand vous voulez dans les réglages d\'abonnement $_temp2, au moins un jour avant le renouvellement.';
  }

  @override
  String manageInStore(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'dans l\'App Store',
      'other': 'dans Google Play',
    });
    return 'Résiliez-le ou modifiez-le $_temp0.';
  }

  @override
  String get subscription => 'Abonnement';

  @override
  String get finishingPurchase => 'Finalisation de votre achat…';

  @override
  String get paidLiveSoon =>
      'Votre paiement est passé. Le jeu en direct s\'ouvre dès qu\'il nous parvient — rechargez dans une minute.';

  @override
  String get checkingOnline => 'Recherche des joueurs en ligne…';

  @override
  String get activateSubscription => 'Activer l\'abonnement';

  @override
  String get activateBody =>
      'Ajoutez cet appareil à un abonnement que vous avez déjà. Scannez le code qu\'un autre de vos appareils affiche sous Abonnement, ou tapez ou collez un code : celui-là, ou un code de secours reçu par e-mail.';

  @override
  String get code => 'Code';

  @override
  String get paste => 'Coller';

  @override
  String get pasteByHand =>
      'Impossible de lire le presse-papiers ici. Touchez longuement le champ du code, puis choisissez Coller.';

  @override
  String get scanCode => 'Scanner un code';

  @override
  String get activate => 'Activer';

  @override
  String get activated => 'Le jeu en direct est ouvert sur cet appareil.';

  @override
  String get noCamera =>
      'Pas de caméra pour scanner ici. Tapez ou collez le code à la place.';

  @override
  String get pointAtCode =>
      'Pointez la caméra vers le code sur votre autre appareil.';

  @override
  String get orTypeCode =>
      'Ou tapez ce code sur l\'autre appareil, sous Activer l\'abonnement :';

  @override
  String get copy => 'Copier';

  @override
  String get copied => 'Copié';

  @override
  String get backupCodes => 'Codes de secours';

  @override
  String get backupCodesHint =>
      'Pour le jour où aucun de vos appareils n\'est à portée de main pour afficher un code. Chacun ajoute un appareil à cet abonnement, une fois. Gardez-les en lieu sûr.';

  @override
  String get showBackupCodes => 'Afficher les codes de secours';

  @override
  String get codeUsedMark => 'utilisé';

  @override
  String get replaceCodes => 'Remplacer les codes';

  @override
  String get replaceCodesTitle => 'Remplacer les codes de secours ?';

  @override
  String get replaceCodesBody =>
      'Ces cinq cessent de fonctionner, et cinq nouveaux les remplacent.';

  @override
  String get replace => 'Remplacer';

  @override
  String get codesMade => 'Nouveaux codes créés.';

  @override
  String get emailCodes => 'Envoyer par e-mail';

  @override
  String get codesSent => 'Envoyés à l\'adresse e-mail de votre abonnement.';

  @override
  String get codesNoAddress =>
      'Cet abonnement n\'a pas d\'adresse e-mail où les envoyer.';

  @override
  String get codesNotSent =>
      'Impossible de les envoyer pour l\'instant. Réessayez plus tard.';

  @override
  String get haveACode => 'Vous avez un code ? Activer';

  @override
  String get privacyShort => 'Confidentialité';

  @override
  String get termsShort => 'Conditions';

  @override
  String get gameTitle => 'La partie';

  @override
  String get checkingGame => 'Vérification de chaque carte de la partie.';

  @override
  String get stillCheckingGame => 'Vérification du reste de la partie…';

  @override
  String get noGameHere =>
      'Aucune partie terminée n\'est conservée à cette adresse.';

  @override
  String gameDoesNotCheck(String reason) {
    return 'Le relevé de cette partie n\'est pas valable : $reason';
  }

  @override
  String get cantCheckGame =>
      'Cet appareil ne peut pas vérifier la donne, il ne peut donc pas montrer la partie.';

  @override
  String trickNumber(int trick) {
    return 'Pli $trick';
  }

  @override
  String seatPlayer(int seat) {
    return 'Joueur $seat';
  }

  @override
  String get seeWholeGame => 'Voir toute la partie';

  @override
  String get shareToWatch => 'Partager un lien pour regarder';

  @override
  String get liveNow => 'En direct';

  @override
  String get watchingNote =>
      'Les mains restent cachées jusqu’à la fin de la partie ; ensuite toute la partie est ici, vérifiée.';

  @override
  String get passingNow => 'Passe des cartes';

  @override
  String get dealingNow => 'Distribution';

  @override
  String toPlayNow(String name) {
    return 'À $name de jouer';
  }

  @override
  String get yourAccount => 'Votre compte';

  @override
  String get signInToKeep =>
      'Connectez-vous, et un nouveau téléphone ou un navigateur qui a tout oublié revient dans ce compte en se connectant de la même façon. De la connexion, seule une forme brouillée de son numéro est gardée : ni nom, ni e-mail.';

  @override
  String get signInToBringBack =>
      'Déjà abonné, et connecté sur votre autre appareil ? Connectez-vous de la même façon pour amener celui-ci dans votre compte.';

  @override
  String signedInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Connecté avec Apple.',
      'other': 'Connecté avec Google.',
    });
    return '$_temp0 Connectez-vous de la même façon sur un nouveau téléphone ou dans un autre navigateur, et cet abonnement vous suit.';
  }

  @override
  String signedInBeforeBuying(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Connecté avec Apple.',
      'other': 'Connecté avec Google.',
    });
    return '$_temp0 Un abonnement acheté ici reste lié à votre compte.';
  }

  @override
  String signInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Se connecter avec Apple',
      'other': 'Se connecter avec Google',
    });
    return '$_temp0';
  }

  @override
  String get accountElsewhere =>
      'Cette connexion est liée à un autre compte Open Hearts. Utiliser ce compte sur cet appareil ? Cet appareil quitte alors le compte où il est maintenant.';

  @override
  String get moveAccountHere => 'Utiliser ce compte ici';

  @override
  String get signedIn => 'Connecté.';

  @override
  String get signedInNoSubscription =>
      'Connecté. Aucun compte n\'est encore lié à cette connexion : abonnez-vous, puis connectez-vous depuis la page de l\'abonnement.';

  @override
  String get signInFailed =>
      'La connexion n\'a pas abouti. Réessayez dans un instant.';

  @override
  String get openElsewhereTitle =>
      'Open Hearts est maintenant ouvert sur un autre appareil';

  @override
  String get openElsewhereBody =>
      'Votre compte joue sur un appareil à la fois, et le dernier ouvert l\'emporte. Celui-ci s\'est retiré : de la table, du jury et de l\'attente. Utilisez-le ici, et c\'est l\'autre qui se retire.';

  @override
  String get inGameElsewhereTitle =>
      'Vous êtes dans une partie sur un autre appareil';

  @override
  String get inGameElsewhereBody => 'Continuer ici ? Cette partie sera perdue.';

  @override
  String get continueHere => 'Continuer ici';

  @override
  String get useItHere => 'L\'utiliser ici';

  @override
  String get liveOpenElsewhere =>
      'Votre compte est utilisé sur un autre appareil.';

  @override
  String get deviceInUse => 'en cours d’utilisation';

  @override
  String get reviewIsLivePlay =>
      'Regarder une partie, et en revoir une déjà jouée, fait partie du jeu en direct.';

  @override
  String get reviewOwnGame =>
      'C\'est votre propre partie, toujours en cours. Elle sera ici une fois terminée.';

  @override
  String get autoSwitch => 'Auto';

  @override
  String get autoPlayLabel => 'Jouer automatiquement la fin de cette donne';

  @override
  String get autoOffered =>
      'Plus rien dans votre main ne peut changer cette donne. Auto la joue pour vous.';

  @override
  String reaction(String code) {
    String _temp0 = intl.Intl.selectLogic(code, {
      'nice': 'Joli',
      'ha': 'Haha',
      'wow': 'Waouh',
      'ouch': 'Aïe',
      'sorry': 'Pardon',
      'gg': 'Bien joué',
      'other': '…',
    });
    return '$_temp0';
  }

  @override
  String reactionSaid(String name, String reaction) {
    return '$name : $reaction';
  }

  @override
  String get react => 'Réagir';

  @override
  String get hideReactions => 'Masquer les réactions des autres';
}
