// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String cardName(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'jota',
      'queen': 'reina',
      'king': 'rey',
      'ace': 'as',
      'other': '$number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'tréboles',
      'diamonds': 'diamantes',
      'spades': 'picas',
      'other': 'corazones',
    });
    return '$_temp0 de $_temp1';
  }

  @override
  String cardWithArticle(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'la jota',
      'queen': 'la reina',
      'king': 'el rey',
      'ace': 'el as',
      'other': 'el $number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'tréboles',
      'diamonds': 'diamantes',
      'spades': 'picas',
      'other': 'corazones',
    });
    return '$_temp0 de $_temp1';
  }

  @override
  String seatLed(String name, String card) {
    return '$name salió con $card';
  }

  @override
  String seatPlayed(String name, String card) {
    return '$name jugó $card';
  }

  @override
  String passDirection(String direction) {
    String _temp0 = intl.Intl.selectLogic(direction, {
      'left': 'Pasa a la izquierda',
      'right': 'Pasa a la derecha',
      'across': 'Pasa al frente',
      'other': 'Sin pase',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstLead => 'El 2 de tréboles abre la primera baza';

  @override
  String refuseFollowSuit(String suit) {
    String _temp0 = intl.Intl.selectLogic(suit, {
      'clubs': 'Tienes que seguir con tréboles',
      'diamonds': 'Tienes que seguir con diamantes',
      'spades': 'Tienes que seguir con picas',
      'other': 'Tienes que seguir con corazones',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstTrickPoints => 'No se juegan puntos en la primera baza';

  @override
  String get refuseHeartsUnbroken => 'Los corazones aún no se han roto';

  @override
  String get refuseOther => 'No puedes jugar esa carta';

  @override
  String get you => 'Tú';

  @override
  String seatNumber(int seat) {
    return 'Asiento $seat';
  }

  @override
  String handHeader(int hand, String pass, int target) {
    return 'Mano $hand  ·  $pass  ·  a $target';
  }

  @override
  String get heartsBroken => 'Los corazones están rotos';

  @override
  String get heartsNotBroken => 'Los corazones no están rotos';

  @override
  String get menu => 'Menú';

  @override
  String get leaveTheTable => 'Dejar la mesa';

  @override
  String get about => 'Acerca de';

  @override
  String get recordCopied => 'Registro copiado';

  @override
  String choosePass(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Elige $count cartas más para pasar',
      one: 'Elige 1 carta más para pasar',
    );
    return '$_temp0';
  }

  @override
  String get passButton => 'Pasar';

  @override
  String passedYou(String name) {
    return '$name te pasó';
  }

  @override
  String passedTo(String name) {
    return 'Pasadas a $name';
  }

  @override
  String get waitingForOthers => 'Esperando a los demás';

  @override
  String seatScores(String name, int total, int taken) {
    return '$name: $total en la partida, $taken en esta mano';
  }

  @override
  String get seatOnTurn => ', en turno';

  @override
  String seatClock(int seconds) {
    return ', $seconds s en el reloj';
  }

  @override
  String get youTakeIt => 'Te la llevas';

  @override
  String takesIt(String name) {
    return 'Se la lleva $name';
  }

  @override
  String get yourTurn => 'Tu turno';

  @override
  String get whatHasGone => 'Lo que ha salido';

  @override
  String stillOut(int hearts, String queen) {
    String _temp0 = intl.Intl.pluralLogic(
      hearts,
      locale: localeName,
      other: '$hearts corazones',
      one: '1 corazón',
      zero: 'Ningún corazón',
    );
    String _temp1 = intl.Intl.selectLogic(queen, {
      'true': ' y la reina',
      'other': '',
    });
    return '$_temp0$_temp1 sin salir';
  }

  @override
  String get nextHand => 'Siguiente mano';

  @override
  String get newGame => 'Nueva partida';

  @override
  String handNumber(int hand) {
    return 'Mano $hand';
  }

  @override
  String get youShotTheMoon => 'Disparaste a la luna';

  @override
  String shotTheMoon(String name) {
    return '$name disparó a la luna';
  }

  @override
  String get shotTheMoonDetail => 'Los 26 — se los llevan todos los demás';

  @override
  String get aShareOfIt => 'Victoria compartida';

  @override
  String get youWin => 'Tú ganas';

  @override
  String namesTie(String names) {
    return 'Empate entre $names';
  }

  @override
  String get listAnd => 'y';

  @override
  String nameWins(String name) {
    return 'Gana $name';
  }

  @override
  String lowestScoreAfter(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'La puntuación más baja tras $hands manos',
      one: 'La puntuación más baja tras 1 mano',
    );
    return '$_temp0';
  }

  @override
  String get copyRecord => 'Copiar registro';

  @override
  String ratingNow(String rating) {
    return 'Clasificación $rating';
  }

  @override
  String ratingMoved(String before, String after) {
    return 'Clasificación $before → $after';
  }

  @override
  String get tagline => 'Código abierto, sin anuncios. Juega solo o en vivo.';

  @override
  String get playSolo => 'Jugar solo';

  @override
  String get stillLookingForRelay => 'Todavía buscando un relé…';

  @override
  String noRelayTakesEvents(String reason) {
    return 'Ningún relé acepta los mensajes de este dispositivo: $reason';
  }

  @override
  String couldNotConnect(String error) {
    return 'No se pudo conectar: $error';
  }

  @override
  String get noRelayAnswered =>
      'Ningún relé respondió. Revisa la conexión y vuelve a intentarlo.';

  @override
  String get tableFilledWithoutYou => 'Esa mesa se llenó sin ti';

  @override
  String get linkCopied => 'Enlace copiado';

  @override
  String get livePlay => 'Juego en vivo';

  @override
  String get yourProfile => 'Tu perfil';

  @override
  String get gameOptions => 'Opciones de partida';

  @override
  String gameLine(int target, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'con clasificación',
      'other': 'sin clasificación',
    });
    return '$target puntos · $_temp0';
  }

  @override
  String get fourSeatsWaiting => 'Cuatro asientos, para quien esté esperando.';

  @override
  String youAreRated(int rating, String provisional, int games) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisional',
      'other': '',
    });
    String _temp1 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'tras $games partidas clasificadas',
      one: 'tras 1 partida clasificada',
    );
    return 'Tu clasificación es $rating$_temp0, $_temp1.';
  }

  @override
  String get playLive => 'Jugar en vivo';

  @override
  String playLiveSpoken(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: 'Jugar en vivo, $online conectados',
      one: 'Jugar en vivo, nadie más conectado',
      zero: 'Jugar en vivo, nadie más conectado',
    );
    return '$_temp0';
  }

  @override
  String onlineCount(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online conectados',
      one: 'Nadie más conectado',
      zero: 'Nadie más conectado',
    );
    return '$_temp0';
  }

  @override
  String get playFriends => 'Jugar con amigos';

  @override
  String get playFriendsDetail =>
      'Una mesa nueva y un enlace para enviar. El enlace de un amigo abre la suya.';

  @override
  String pricePerYear(String amount) {
    return '$amount al año';
  }

  @override
  String get seatsOrFriends =>
      'Cuatro asientos, para quien esté esperando — o un enlace que envías a tres amigos.';

  @override
  String get subscribe => 'Suscribirse';

  @override
  String get aloneIsFree => 'Jugar solo es gratis, y siempre lo será.';

  @override
  String get findingPlayers => 'Buscando jugadores';

  @override
  String waitedLine(int seconds, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', $others más esperando',
      one: ', 1 más esperando',
      zero: '',
    );
    return '$seconds s$_temp0 — los bots ocupan los asientos libres a los diez';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get roomSendLink =>
      'Envía el enlace. La mesa empieza diez segundos después de que alguien se una.';

  @override
  String roomStartingIn(int seconds) {
    return 'Empieza en $seconds s — los asientos vacíos son para bots';
  }

  @override
  String get shareTheLink => 'Compartir el enlace';

  @override
  String nameIsYou(String name) {
    return '$name (tú)';
  }

  @override
  String get emptySeat => 'un bot, salvo que alguien se una';

  @override
  String get startNow => 'Empezar ya';

  @override
  String get leave => 'Salir';

  @override
  String ratedSpoken(int rating, String provisional) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisional',
      'other': '',
    });
    return 'clasificación $rating$_temp0';
  }

  @override
  String get roomOtherBuild =>
      'La app de alguien tiene otra versión que la tuya — una de las dos es más antigua. Actualiza y vuelve a intentarlo.';

  @override
  String get noDealPageStopped =>
      'El reparto que mantiene honestas las cartas dejó de funcionar en esta página. Recárgala para empezar de nuevo.';

  @override
  String get noDealAppStopped =>
      'El reparto que mantiene honestas las cartas dejó de funcionar. Reinicia la app para empezar de nuevo.';

  @override
  String get noDealBrowser =>
      'Este navegador no puede ejecutar el reparto que mantiene honestas las cartas. Prueba con un Chrome, Firefox o Safari actual.';

  @override
  String get noDealBuild =>
      'Esta versión no puede ejecutar el reparto que mantiene honestas las cartas, así que no puede sentarse a una mesa en vivo.';

  @override
  String get serviceUnreachable =>
      'No se pudo contactar con el servicio. Inténtalo de nuevo en un momento.';

  @override
  String get codeNotForThisDevice => 'Ese código no es para este dispositivo.';

  @override
  String serviceRefusal(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noSubscription': 'No hay suscripción.',
      'fiveDevices':
          'Esta suscripción ya tiene todos los dispositivos que admite.',
      'notACode': 'Eso no es un código.',
      'noSuchCode': 'Ese código no existe.',
      'codeUsed': 'Ese código ya se usó.',
      'codeRunOut': 'Ese código ha caducado.',
      'notADevice': 'Ese dispositivo no está en esta suscripción.',
      'onAnotherSubscription':
          'Este dispositivo está en otra suscripción. Quítalo de allí primero.',
      'clockOff': 'El reloj de este dispositivo va desfasado. Ajústalo y vuelve a intentarlo.',
      'notAStore': 'Esa no es una tienda que el servicio conozca.',
      'noProof': 'La tienda no dio ningún comprobante de la compra.',
      'notFromStore': 'Esa compra no viene de la tienda.',
      'notPaid': 'La tienda dice que esa compra no está pagada.',
      'storeNotAnswering':
          'La tienda no responde. Vuelve a intentarlo en un momento.',
      'storeNotSetUp': 'La compra en la tienda aún no está abierta.',
      'other': 'El servicio lo rechazó.',
    });
    return '$_temp0';
  }

  @override
  String get buyingNotOpen =>
      'Todavía no se puede comprar en este dispositivo.';

  @override
  String get shopUnreachable =>
      'No se pudo contactar con la tienda. Inténtalo de nuevo en un momento.';

  @override
  String get shopNotOpen => 'La tienda aún no está abierta.';

  @override
  String openUntil(String day) {
    return 'Activo en este dispositivo hasta el $day';
  }

  @override
  String get pointRating =>
      'Una clasificación propia, a partir de resultados que firman los cuatro.';

  @override
  String get pointDeal =>
      'Las cartas se reparten entre los cuatro. Ningún servidor ve una mano, tampoco el nuestro.';

  @override
  String get whatMoneyPaysFor =>
      'Jugar solo es gratis y siempre lo será, igual que los registros, el motor y cada línea de esto. Lo que pagas cubre la parte que nos cuesta mantener: poner a los jugadores en contacto, un relé cuando dos dispositivos no encuentran un camino directo, y un jurado cuando una mesa se queda sola.';

  @override
  String get cancelWhenever =>
      'Cancela cuando quieras; el año que pagaste termina por sí solo.';

  @override
  String get storeSubscriptionLater =>
      'En un teléfono será la suscripción de la propia tienda. Hasta que la app esté en las tiendas, el juego en vivo se compra en la web.';

  @override
  String get subscriptionIsYours =>
      'Una suscripción es tuya, no de un dispositivo. Añade otro mostrándole este código — solo necesita su cámara — y quita uno cuando quieras.';

  @override
  String get yourDevices => 'Tus dispositivos';

  @override
  String devicesOf(int count, int most) {
    return '$count de $most';
  }

  @override
  String get addDevice => 'Añadir un dispositivo';

  @override
  String get pointTheCamera =>
      'Apunta la cámara del otro dispositivo aquí. Sirve durante diez minutos y para un solo dispositivo: una foto de esta pantalla mañana no vale nada.';

  @override
  String get sendLinkInstead => 'Enviar el enlace';

  @override
  String get thisDevice => 'Este dispositivo';

  @override
  String deviceSince(String day) {
    return 'desde $day';
  }

  @override
  String get dropThisOne => 'Quitar este';

  @override
  String get drop => 'Quitar';

  @override
  String get codeToScan => 'Un código para escanear';

  @override
  String get notAPicture => 'Eso no parece una imagen.';

  @override
  String couldNotOpen(String error) {
    return 'No se pudo abrir: $error';
  }

  @override
  String get done => 'Listo';

  @override
  String get yourName => 'Tu nombre';

  @override
  String get howYouLook => 'Tu aspecto';

  @override
  String colourNumber(int number) {
    return 'Color $number';
  }

  @override
  String get useAPhoto => 'Usar una foto';

  @override
  String get myInitials => 'Mis iniciales';

  @override
  String avatarIcon(String icon) {
    String _temp0 = intl.Intl.selectLogic(icon, {
      'pets': 'Huella',
      'rabbit': 'Conejo',
      'bug': 'Bicho',
      'sailing': 'Velero',
      'rocket': 'Cohete',
      'anchor': 'Ancla',
      'castle': 'Castillo',
      'diamond': 'Diamante',
      'spa': 'Hoja',
      'park': 'Árbol',
      'star': 'Estrella',
      'bolt': 'Rayo',
      'sun': 'Sol',
      'moon': 'Luna',
      'flower': 'Flor',
      'cake': 'Pastel',
      'coffee': 'Café',
      'music': 'Nota musical',
      'game': 'Mando',
      'umbrella': 'Paraguas',
      'bike': 'Bicicleta',
      'piano': 'Piano',
      'palette': 'Paleta',
      'other': 'Copo de nieve',
    });
    return '$_temp0';
  }

  @override
  String paceKnown(String pace, int seconds) {
    String _temp0 = intl.Intl.selectLogic(pace, {
      'brisk': 'ágil',
      'steady': 'constante',
      'unhurried': 'tranquilo',
      'slow': 'pausado',
      'other': 'aún desconocido',
    });
    String _temp1 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds segundos',
      one: '1 segundo',
    );
    return 'Juegas a un ritmo $_temp0, unos $_temp1 por carta, y te sentamos con jugadores de ritmo parecido';
  }

  @override
  String get paceUnknown =>
      'Todavía no conocemos tu ritmo. Tras una o dos partidas en vivo te sentaremos con jugadores de ritmo parecido';

  @override
  String get rating => 'Clasificación';

  @override
  String get countingGames => 'Contando tus partidas…';

  @override
  String get relaysSilent =>
      'Los relés no respondieron, así que ahora no se puede mostrar';

  @override
  String get playRatedForRating =>
      'Juega una partida en vivo con clasificación y tendrás una';

  @override
  String ratingProvisionalFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Provisional, de $games partidas',
      one: 'Provisional, de una partida',
    );
    return '$_temp0';
  }

  @override
  String ratingFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'De $games partidas',
      one: 'De una partida',
    );
    return '$_temp0';
  }

  @override
  String get yourGames => 'Tus partidas';

  @override
  String get gamesLive => 'En vivo';

  @override
  String get gamesAlone => 'Solo';

  @override
  String get gamesPlayed => 'jugadas';

  @override
  String get gamesWon => 'ganadas';

  @override
  String get gamesAverage => 'media';

  @override
  String get gamesBest => 'mejor';

  @override
  String get yourPicture => 'Tu imagen';

  @override
  String get useIt => 'Usarla';

  @override
  String get cropHelp =>
      'Arrastra para moverla, pellizca para agrandarla.\nLo que queda en el círculo es tu imagen.';

  @override
  String get pictureFlagged =>
      'Este dispositivo pensó que no querrías ver esta imagen en la mesa. Es una suposición, hecha aquí, y puede equivocarse.';

  @override
  String showPicture(String name) {
    return 'Mostrar la imagen de $name';
  }

  @override
  String hidePicture(String name) {
    return 'Ocultar la imagen de $name';
  }

  @override
  String get pictureChoiceNote =>
      'Solo en este dispositivo, y solo su imagen: su nombre y su puntuación se quedan.';

  @override
  String get waitingToReconnect => 'Esperando a que los demás se reconecten';

  @override
  String get askingTheJury => 'Consultando al jurado';

  @override
  String get noJurorOnline =>
      'Nadie en línea para formar un jurado — esperando';

  @override
  String get waitingForTheJury => 'Esperando al jurado';

  @override
  String get openingDepartedHand => 'Abriendo la mano de un jugador que se fue';

  @override
  String get nobodyClaimsTwo => 'Nadie tiene el 2♣ — el reparto está atascado';

  @override
  String bootPlayer(String name) {
    return 'Expulsar a $name';
  }

  @override
  String get cannotDealTitle => 'Este dispositivo no puede repartir';

  @override
  String get cannotDealLabel => 'El reparto dejó de funcionar aquí';

  @override
  String cannotDealWhy(String reason) {
    return 'Así que has dejado la mesa, y los demás siguen con un bot en tu asiento. Al recargar la página el reparto empieza de nuevo. ($reason)';
  }

  @override
  String get connectionFailure => 'Fallo de conexión';

  @override
  String get jurorQuorumLost => 'Sin quórum de jurados';

  @override
  String get jurorQuorumLostWhy =>
      'Quedan muy pocos jurados conectados de los que guardan los asientos de los bots, así que la mano no puede seguir. La partida termina aquí, sin puntuar.';

  @override
  String get onWithIt => 'Seguir';

  @override
  String get home => 'Inicio';

  @override
  String hereCount(int here, int humans, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'con clasificación',
      'other': 'sin clasificación',
    });
    return '$here de $humans aquí  ·  $_temp0';
  }

  @override
  String get botTookYourSeat => 'Un bot ocupó tu asiento';

  @override
  String get tableCouldNotHear =>
      'La mesa no recibía noticias tuyas y siguió sin ti.';

  @override
  String get back => 'Volver';

  @override
  String get waitingForJurors =>
      'Esperando jurados que guarden las manos de los bots';

  @override
  String get dealing => 'Repartiendo';

  @override
  String get dealingKeys => 'Repartiendo — claves';

  @override
  String shuffling(int turn) {
    return 'Barajando ($turn de 4)';
  }

  @override
  String get dealingTheCards => 'Repartiendo las cartas';

  @override
  String get openingTheCards => 'Abriendo las cartas';

  @override
  String get gameEndsAt => 'La partida termina cuando alguien llega a';

  @override
  String targetPoints(int target) {
    return '$target puntos';
  }

  @override
  String get ratedMovesRatings =>
      'Las partidas con clasificación mueven la tuya, y la de los bots';

  @override
  String get rated => 'Con clasificación';

  @override
  String get unrated => 'Sin clasificación';

  @override
  String get aboutBlurb =>
      'Corazones, de código abierto. Juega solo contra la casa, o en vivo: los cuatro se reparten las cartas entre ellos, y ningún servidor ve una mano.';

  @override
  String get build => 'Versión';

  @override
  String get published => 'Publicada';

  @override
  String buildIsUp(String build) {
    return '$build ya está disponible';
  }

  @override
  String get livePaused =>
      'El juego en vivo está en pausa por ahora. Jugar solo sigue abierto.';

  @override
  String get updateDueWeb =>
      'Esta versión está desactualizada. Recarga para obtener la nueva.';

  @override
  String get updateDueApp =>
      'Esta versión está desactualizada. Actualiza la app para obtener la nueva.';

  @override
  String get reload => 'Recargar';

  @override
  String get tellUsWhatsBroken => 'Dinos qué falla';

  @override
  String get feedbackIntro =>
      '¿Qué pasó y qué esperabas? Con una o dos frases basta.';

  @override
  String get feedbackHint => 'Qué pasó';

  @override
  String get feedbackWithRecord =>
      'Enviar también el registro de esta partida, para poder repetir la mano';

  @override
  String get feedbackSentWithIt => 'Se envía con ello';

  @override
  String get feedbackSend => 'Enviar';

  @override
  String get feedbackIsPublic =>
      'Esto abre una incidencia en GitHub, que cualquiera puede leer. No incluyas nada privado.';

  @override
  String get feedbackCopied => 'Copiado. Pégalo en la página que se abrió.';

  @override
  String feedbackCopiedTo(String to) {
    return 'Copiado. Pégalo en $to';
  }

  @override
  String statsRecent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Tus últimas $count partidas en solitario',
      one: 'Tu última partida en solitario',
    );
    return '$_temp0';
  }

  @override
  String statsRecentSpoken(int count, String scores, int average) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Puntuaciones finales de tus últimas $count partidas en solitario, de la más antigua a la más reciente: $scores. Media $average.',
      one:
          'Puntuación final de tu última partida en solitario: $scores. Media $average.',
    );
    return '$_temp0';
  }

  @override
  String statsAverage(int average) {
    return 'media $average';
  }

  @override
  String get statsLowerIsBetter =>
      'Puntuaciones finales, de la más antigua a la más reciente. Cuanto más bajo, mejor.';

  @override
  String get statsQueens => 'Reina de picas tomada';

  @override
  String get statsMoonsShot => 'Lunas disparadas';

  @override
  String get statsMoonsBlocked => 'Lunas bloqueadas';

  @override
  String statsOverHands(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'En $hands manos en solitario',
      one: 'En 1 mano en solitario',
    );
    return '$_temp0';
  }

  @override
  String seatWhere(String where) {
    String _temp0 = intl.Intl.selectLogic(where, {
      'left': 'a tu izquierda',
      'across': 'enfrente',
      'other': 'a tu derecha',
    });
    return ', $_temp0';
  }

  @override
  String takesPoints(String who, int points) {
    String _temp0 = intl.Intl.pluralLogic(
      points,
      locale: localeName,
      other: '$points puntos',
      one: '1 punto',
    );
    return '$who, $_temp0';
  }

  @override
  String sheetRow(String name, int delta, int total) {
    return '$name: $delta en esta mano, $total en la partida';
  }

  @override
  String get joinHouseholdTitle => '¿Unirse a esta suscripción?';

  @override
  String get joinHouseholdBody =>
      'Este enlace añade este dispositivo a una suscripción de juego en vivo. Únete solo si viene de ti o de alguien con quien la compartes.';

  @override
  String get join => 'Unirse';

  @override
  String get notNow => 'Ahora no';

  @override
  String get privacyPolicy => 'Política de privacidad';

  @override
  String get termsOfUse => 'Condiciones de uso';

  @override
  String get manageSubscription => 'Gestionar suscripción';

  @override
  String get manageSubscriptionHint =>
      'Cancela, cambia la tarjeta o mira los recibos.';

  @override
  String get managedWhereBought =>
      'Esta suscripción se gestiona donde se compró.';

  @override
  String get licenceNotForThisDevice =>
      'La respuesta del servicio no era una licencia para este dispositivo.';

  @override
  String get storeFailed =>
      'La tienda no completó la compra. Vuelve a intentarlo en un momento.';

  @override
  String get nothingToRestore =>
      'No se encontró ninguna suscripción que restaurar en esta cuenta de la tienda.';

  @override
  String get restorePurchases => 'Restaurar compras';

  @override
  String get storePending =>
      'La tienda está esperando para aprobar el pago. El juego en vivo se abrirá aquí en cuanto lo haga.';

  @override
  String storeRenewal(String price, String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'cuenta de Apple',
      'other': 'cuenta de Google',
    });
    String _temp1 = intl.Intl.selectLogic(store, {
      'apple': 'App Store',
      'other': 'Google Play',
    });
    return '$price al año, cobrado a tu $_temp0 al confirmar. Se renueva sola cada año hasta que la canceles, cuando quieras, en los ajustes de suscripciones de $_temp1, al menos un día antes de la renovación.';
  }

  @override
  String manageInStore(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'App Store',
      'other': 'Google Play',
    });
    return 'Cancélala o cámbiala en $_temp0.';
  }

  @override
  String get subscription => 'Suscripción';

  @override
  String get finishingPurchase => 'Terminando tu compra…';

  @override
  String get paidLiveSoon =>
      'Tu pago se ha realizado. El juego en vivo se abre en cuanto nos llegue: recarga en un minuto.';
}
