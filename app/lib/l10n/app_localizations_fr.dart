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
  String get tagline => 'Open source, sans publicité. Jouez seul ou en direct.';

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
  String get fourSeatsWaiting => 'Quatre places, pour ceux qui attendent.';

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
  String get playFriendsDetail =>
      'Une nouvelle table, et un lien à envoyer. Le lien d\'un ami ouvre la sienne.';

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
  String get aloneIsFree => 'Jouer seul est gratuit, et le restera.';

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
      'fiveDevices': 'Déjà cinq appareils.',
      'notACode': 'Ce n\'est pas un code.',
      'noSuchCode': 'Ce code n\'existe pas.',
      'codeUsed': 'Ce code a déjà servi.',
      'codeRunOut': 'Ce code a expiré.',
      'notADevice': 'Cet appareil ne fait pas partie de cet abonnement.',
      'onAnotherSubscription': 'Cet appareil fait partie d\'un autre abonnement. Retirez-le d\'abord de celui-ci.',
      'clockOff': 'L\'horloge de cet appareil a plus de cinq minutes d\'écart. Réglez-la et réessayez.',
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
      'Jouer seul est gratuit et le restera, tout comme les relevés, le moteur et chaque ligne de ce code. L\'argent paie ce qui nous coûte à faire tourner : vous mettre en relation, un relais quand deux appareils ne trouvent pas de chemin direct, et un juré quand une table est laissée seule.';

  @override
  String get cancelWhenever =>
      'Résiliez quand vous voulez ; l\'année payée s\'arrête d\'elle-même.';

  @override
  String get storeSubscriptionLater =>
      'Sur téléphone, ce sera l\'abonnement de la boutique d\'applications. En attendant que l\'application y soit, le jeu en direct s\'achète sur le web.';

  @override
  String get subscriptionIsYours =>
      'Un abonnement est à vous, pas à un appareil. Ajoutez-en un autre en lui montrant ce code — son appareil photo suffit — et retirez-en un quand vous voulez.';

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
  String get waitingToReconnect => 'En attente de la reconnexion des autres';

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
  String get waitingForJurors =>
      'En attente de jurés pour tenir les mains des bots';

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
  String get aboutBlurb =>
      'Hearts, en open source. Jouez seul contre la maison, ou en direct : vous distribuez les cartes entre vous quatre, et aucun serveur ne voit une main.';

  @override
  String get build => 'Version';

  @override
  String get published => 'Publiée';

  @override
  String buildIsUp(String build) {
    return '$build est disponible';
  }

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
}
