// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String cardName(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'valete',
      'queen': 'dama',
      'king': 'rei',
      'ace': 'ás',
      'other': '$number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'paus',
      'diamonds': 'ouros',
      'spades': 'espadas',
      'other': 'copas',
    });
    return '$_temp0 de $_temp1';
  }

  @override
  String cardWithArticle(String rank, String number, String suit) {
    String _temp0 = intl.Intl.selectLogic(rank, {
      'jack': 'o valete',
      'queen': 'a dama',
      'king': 'o rei',
      'ace': 'o ás',
      'other': 'o $number',
    });
    String _temp1 = intl.Intl.selectLogic(suit, {
      'clubs': 'paus',
      'diamonds': 'ouros',
      'spades': 'espadas',
      'other': 'copas',
    });
    return '$_temp0 de $_temp1';
  }

  @override
  String seatLed(String name, String card) {
    return '$name saiu com $card';
  }

  @override
  String seatPlayed(String name, String card) {
    return '$name jogou $card';
  }

  @override
  String passDirection(String direction) {
    String _temp0 = intl.Intl.selectLogic(direction, {
      'left': 'Passe para a esquerda',
      'right': 'Passe para a direita',
      'across': 'Passe para a frente',
      'other': 'Sem passe',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstLead => 'O 2 de paus abre a primeira vaza';

  @override
  String refuseFollowSuit(String suit) {
    String _temp0 = intl.Intl.selectLogic(suit, {
      'clubs': 'Você precisa jogar paus',
      'diamonds': 'Você precisa jogar ouros',
      'spades': 'Você precisa jogar espadas',
      'other': 'Você precisa jogar copas',
    });
    return '$_temp0';
  }

  @override
  String get refuseFirstTrickPoints => 'Nada de pontos na primeira vaza';

  @override
  String get refuseHeartsUnbroken => 'As copas ainda não foram quebradas';

  @override
  String get refuseOther => 'Você não pode jogar essa carta';

  @override
  String get you => 'Você';

  @override
  String seatNumber(int seat) {
    return 'Lugar $seat';
  }

  @override
  String handHeader(int hand, String pass, int target) {
    return 'Mão $hand  ·  $pass  ·  até $target';
  }

  @override
  String get heartsBroken => 'As copas foram quebradas';

  @override
  String get heartsNotBroken => 'As copas não foram quebradas';

  @override
  String get menu => 'Menu';

  @override
  String get leaveTheTable => 'Sair da mesa';

  @override
  String get about => 'Sobre';

  @override
  String get language => 'Idioma';

  @override
  String get deviceLanguage => 'O mesmo do aparelho';

  @override
  String get recordCopied => 'Registro copiado';

  @override
  String choosePass(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Escolha mais $count cartas para passar',
      one: 'Escolha mais 1 carta para passar',
    );
    return '$_temp0';
  }

  @override
  String get passButton => 'Passar';

  @override
  String passedYou(String name) {
    return '$name passou para você';
  }

  @override
  String passedTo(String name) {
    return 'Passadas para $name';
  }

  @override
  String get waitingForOthers => 'Esperando os outros';

  @override
  String seatScores(String name, int total, int taken) {
    return '$name: $total na partida, $taken nesta mão';
  }

  @override
  String get seatOnTurn => ', na vez';

  @override
  String seatClock(int seconds) {
    return ', $seconds s no relógio';
  }

  @override
  String get youTakeIt => 'Você leva';

  @override
  String takesIt(String name) {
    return '$name leva';
  }

  @override
  String get yourTurn => 'Sua vez';

  @override
  String get whatHasGone => 'O que já saiu';

  @override
  String stillOut(int hearts, String queen) {
    String _temp0 = intl.Intl.pluralLogic(
      hearts,
      locale: localeName,
      other: '$hearts copas',
      one: '1 copa',
      zero: 'Nenhuma copa',
    );
    String _temp1 = intl.Intl.selectLogic(queen, {
      'true': ' e a dama',
      'other': '',
    });
    return '$_temp0$_temp1 ainda por sair';
  }

  @override
  String get nextHand => 'Próxima mão';

  @override
  String get newGame => 'Nova partida';

  @override
  String get playAgain => 'Jogar de novo';

  @override
  String handNumber(int hand) {
    return 'Mão $hand';
  }

  @override
  String get youShotTheMoon => 'Você atirou na lua';

  @override
  String shotTheMoon(String name) {
    return '$name atirou na lua';
  }

  @override
  String get shotTheMoonDetail => 'Todos os 26 — vão para todos os outros';

  @override
  String get aShareOfIt => 'Vitória dividida';

  @override
  String get youWin => 'Você venceu';

  @override
  String namesTie(String names) {
    return 'Empate entre $names';
  }

  @override
  String get listAnd => 'e';

  @override
  String nameWins(String name) {
    return '$name venceu';
  }

  @override
  String lowestScoreAfter(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Menor pontuação depois de $hands mãos',
      one: 'Menor pontuação depois de 1 mão',
    );
    return '$_temp0';
  }

  @override
  String get copyRecord => 'Copiar registro';

  @override
  String ratingNow(String rating) {
    return 'Rating $rating';
  }

  @override
  String ratingMoved(String before, String after) {
    return 'Rating $before → $after';
  }

  @override
  String get tagline => 'Jogo de cartas Copas de código aberto, sem anúncios';

  @override
  String get playSolo => 'Jogar sozinho';

  @override
  String get stillLookingForRelay => 'Ainda procurando um relay…';

  @override
  String noRelayTakesEvents(String reason) {
    return 'Nenhum relay aceita as mensagens deste aparelho: $reason';
  }

  @override
  String couldNotConnect(String error) {
    return 'Não foi possível conectar: $error';
  }

  @override
  String get noRelayAnswered =>
      'Nenhum relay respondeu. Verifique a conexão e tente de novo.';

  @override
  String get tableFilledWithoutYou => 'Essa mesa encheu sem você';

  @override
  String get linkCopied => 'Link copiado';

  @override
  String get livePlay => 'Jogo ao vivo';

  @override
  String get yourProfile => 'Seu perfil';

  @override
  String get gameOptions => 'Opções da partida';

  @override
  String gameLine(int target, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'ranqueada',
      'other': 'não ranqueada',
    });
    return '$target pontos · $_temp0';
  }

  @override
  String youAreRated(int rating, String provisional, int games) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisório',
      'other': '',
    });
    String _temp1 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'de $games partidas ranqueadas',
      one: 'de 1 partida ranqueada',
    );
    return 'Seu rating é $rating$_temp0, $_temp1.';
  }

  @override
  String get playLive => 'Jogar ao vivo';

  @override
  String playLiveSpoken(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: 'Jogar ao vivo, $online online',
      one: 'Jogar ao vivo, mais ninguém online',
      zero: 'Jogar ao vivo, mais ninguém online',
    );
    return '$_temp0';
  }

  @override
  String onlineCount(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online online',
      one: 'Mais ninguém online',
      zero: 'Mais ninguém online',
    );
    return '$_temp0';
  }

  @override
  String get playFriends => 'Jogar com amigos';

  @override
  String pricePerYear(String amount) {
    return '$amount por ano';
  }

  @override
  String get seatsOrFriends =>
      'Quatro lugares, para quem estiver esperando — ou um link que você manda para três amigos.';

  @override
  String get subscribe => 'Assinar';

  @override
  String get aloneIsFree => 'Jogar sozinho é grátis, e sempre vai ser.';

  @override
  String get findingPlayers => 'Procurando jogadores';

  @override
  String waitedLine(int seconds, int others) {
    String _temp0 = intl.Intl.pluralLogic(
      others,
      locale: localeName,
      other: ', mais $others esperando',
      one: ', mais 1 esperando',
      zero: '',
    );
    return '$seconds s$_temp0 — bots ocupam os lugares vazios aos dez';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get roomSendLink =>
      'Envie o link. A mesa começa dez segundos depois que alguém entrar.';

  @override
  String roomStartingIn(int seconds) {
    return 'Começa em $seconds s — lugares vazios ficam com bots';
  }

  @override
  String get shareTheLink => 'Compartilhar o link';

  @override
  String nameIsYou(String name) {
    return '$name (você)';
  }

  @override
  String get emptySeat => 'um bot, a não ser que alguém entre';

  @override
  String get startNow => 'Começar agora';

  @override
  String get leave => 'Sair';

  @override
  String ratedSpoken(int rating, String provisional) {
    String _temp0 = intl.Intl.selectLogic(provisional, {
      'true': ', provisório',
      'other': '',
    });
    return 'rating $rating$_temp0';
  }

  @override
  String get roomOtherBuild =>
      'O app de alguém está em outra versão que a sua — um de vocês está desatualizado. Atualize e tente de novo.';

  @override
  String get noDealPageStopped =>
      'A distribuição que mantém as cartas honestas parou de funcionar nesta página. Recarregue para começar de novo.';

  @override
  String get noDealAppStopped =>
      'A distribuição que mantém as cartas honestas parou de funcionar. Reinicie o app para começar de novo.';

  @override
  String get noDealBrowser =>
      'Este navegador não consegue rodar a distribuição que mantém as cartas honestas. Tente um Chrome, Firefox ou Safari atual.';

  @override
  String get noDealBuild =>
      'Esta versão não consegue rodar a distribuição que mantém as cartas honestas, então não pode sentar a uma mesa ao vivo.';

  @override
  String get serviceUnreachable =>
      'Não foi possível falar com o serviço. Tente de novo daqui a pouco.';

  @override
  String get codeNotForThisDevice => 'Esse código não é para este aparelho.';

  @override
  String serviceRefusal(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noSubscription': 'Nenhuma assinatura.',
      'fiveDevices': 'Esta assinatura já tem todos os aparelhos que pode ter.',
      'notACode': 'Isso não é um código.',
      'noSuchCode': 'Esse código não existe.',
      'codeUsed': 'Esse código já foi usado.',
      'codeRunOut': 'Esse código expirou.',
      'notADevice': 'Esse aparelho não está nesta assinatura.',
      'onAnotherSubscription':
          'Este aparelho está em outra assinatura. Remova-o de lá primeiro.',
      'clockOff':
          'O relógio deste aparelho está errado. Acerte-o e tente de novo.',
      'notAStore': 'Essa não é uma loja que o serviço conheça.',
      'noProof': 'A loja não deu nenhum comprovante da compra.',
      'notFromStore': 'Essa compra não veio da loja.',
      'notPaid': 'A loja diz que essa compra não foi paga.',
      'storeNotAnswering':
          'A loja não está respondendo. Tente de novo daqui a pouco.',
      'storeNotSetUp': 'A compra na loja ainda não está aberta.',
      'signInRefused':
          'Não foi possível confirmar essa entrada. Tente de novo.',
      'accountElsewhere': 'Essa conta já está em outro aparelho.',
      'accountNowhere': 'Ninguém entrou aqui com essa conta antes.',
      'signInNotSetUp': 'Entrar com uma conta ainda não está aberto.',
      'other': 'O serviço recusou.',
    });
    return '$_temp0';
  }

  @override
  String get buyingNotOpen => 'Ainda não dá para comprar neste aparelho.';

  @override
  String get shopUnreachable =>
      'Não foi possível falar com a loja. Tente de novo daqui a pouco.';

  @override
  String get shopNotOpen => 'A loja ainda não abriu.';

  @override
  String openUntil(String day) {
    return 'Liberado neste aparelho até $day';
  }

  @override
  String get pointRating =>
      'Um rating só seu, a partir de resultados que os quatro assinam.';

  @override
  String get pointDeal =>
      'As cartas são distribuídas entre vocês quatro. Nenhum servidor vê uma mão, nem o nosso.';

  @override
  String get whatMoneyPaysFor =>
      'Jogar sozinho é grátis e sempre vai ser, assim como os registros, o motor e cada linha disto. O que o dinheiro paga é a parte que custa para mantermos: colocar vocês em contato, um relay quando dois aparelhos não acham um caminho direto, e um júri quando uma mesa fica sozinha.';

  @override
  String get cancelWhenever =>
      'Cancele quando quiser; o ano que você pagou termina sozinho.';

  @override
  String get storeSubscriptionLater =>
      'No celular, será a assinatura da própria loja. Até o app chegar às lojas, o jogo ao vivo é comprado na web.';

  @override
  String get subscriptionIsYours =>
      'Uma assinatura é sua, não de um aparelho. Adicione outro mostrando este código — só precisa da câmera dele — e remova um quando quiser.';

  @override
  String get yourDevices => 'Seus aparelhos';

  @override
  String devicesOf(int count, int most) {
    return '$count de $most';
  }

  @override
  String get addDevice => 'Adicionar um aparelho';

  @override
  String get pointTheCamera =>
      'Aponte a câmera do outro aparelho para cá. Vale por dez minutos e para um só aparelho: uma foto desta tela amanhã não vale nada.';

  @override
  String get sendLinkInstead => 'Enviar o link';

  @override
  String get thisDevice => 'Este aparelho';

  @override
  String deviceSince(String day) {
    return 'desde $day';
  }

  @override
  String get dropThisOne => 'Remover este';

  @override
  String get drop => 'Remover';

  @override
  String get codeToScan => 'Um código para escanear';

  @override
  String get notAPicture => 'Isso não parece uma imagem.';

  @override
  String couldNotOpen(String error) {
    return 'Não foi possível abrir: $error';
  }

  @override
  String get done => 'Pronto';

  @override
  String get yourName => 'Seu nome';

  @override
  String get howYouLook => 'Sua aparência';

  @override
  String colourNumber(int number) {
    return 'Cor $number';
  }

  @override
  String get useAPhoto => 'Usar uma foto';

  @override
  String get myInitials => 'Minhas iniciais';

  @override
  String avatarIcon(String icon) {
    String _temp0 = intl.Intl.selectLogic(icon, {
      'pets': 'Pata',
      'rabbit': 'Coelho',
      'bug': 'Inseto',
      'sailing': 'Veleiro',
      'rocket': 'Foguete',
      'anchor': 'Âncora',
      'castle': 'Castelo',
      'diamond': 'Diamante',
      'spa': 'Folha',
      'park': 'Árvore',
      'star': 'Estrela',
      'bolt': 'Raio',
      'sun': 'Sol',
      'moon': 'Lua',
      'flower': 'Flor',
      'cake': 'Bolo',
      'coffee': 'Café',
      'music': 'Nota musical',
      'game': 'Controle de jogo',
      'umbrella': 'Guarda-chuva',
      'bike': 'Bicicleta',
      'piano': 'Piano',
      'palette': 'Paleta',
      'other': 'Floco de neve',
    });
    return '$_temp0';
  }

  @override
  String paceKnown(String pace, int seconds) {
    String _temp0 = intl.Intl.selectLogic(pace, {
      'brisk': 'ágil',
      'steady': 'constante',
      'unhurried': 'tranquilo',
      'slow': 'lento',
      'other': 'ainda desconhecido',
    });
    String _temp1 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds segundos',
      one: '1 segundo',
    );
    return 'Você joga num ritmo $_temp0, cerca de $_temp1 por carta, e senta com jogadores de ritmo parecido';
  }

  @override
  String get paceUnknown =>
      'Ainda não sabemos o seu ritmo. Depois de uma ou duas partidas ao vivo, você vai sentar com jogadores de ritmo parecido';

  @override
  String get rating => 'Rating';

  @override
  String get countingGames => 'Contando suas partidas…';

  @override
  String get relaysSilent =>
      'Os relays não responderam, então não dá para mostrar agora';

  @override
  String get playRatedForRating =>
      'Jogue uma partida ranqueada ao vivo e você terá um';

  @override
  String ratingProvisionalFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'Provisório, de $games partidas',
      one: 'Provisório, de uma partida',
    );
    return '$_temp0';
  }

  @override
  String ratingFrom(int games) {
    String _temp0 = intl.Intl.pluralLogic(
      games,
      locale: localeName,
      other: 'De $games partidas',
      one: 'De uma partida',
    );
    return '$_temp0';
  }

  @override
  String get yourGames => 'Suas partidas';

  @override
  String get gamesLive => 'Ao vivo';

  @override
  String get gamesAlone => 'Sozinho';

  @override
  String get gamesPlayed => 'jogadas';

  @override
  String get gamesWon => 'vencidas';

  @override
  String get gamesAverage => 'média';

  @override
  String get gamesBest => 'melhor';

  @override
  String get yourPicture => 'Sua imagem';

  @override
  String get useIt => 'Usar';

  @override
  String get cropHelp =>
      'Arraste para mover, use dois dedos para aumentar.\nO que está no círculo é a sua imagem.';

  @override
  String get pictureFlagged =>
      'Este aparelho achou que você não ia querer esta imagem na mesa. É um palpite, feito aqui, e pode estar errado.';

  @override
  String showPicture(String name) {
    return 'Mostrar a imagem de $name';
  }

  @override
  String hidePicture(String name) {
    return 'Esconder a imagem de $name';
  }

  @override
  String get pictureChoiceNote =>
      'Só neste aparelho, e só a imagem: o nome e a pontuação continuam.';

  @override
  String get waitingToReconnect => 'Esperando os outros reconectarem';

  @override
  String get askingTheJury => 'Consultando o júri';

  @override
  String get noJurorOnline =>
      'Ninguém online para formar um júri — esperando alguém';

  @override
  String get waitingForTheJury => 'Esperando o júri';

  @override
  String get openingDepartedHand => 'Abrindo a mão de um jogador que saiu';

  @override
  String get nobodyClaimsTwo => 'Ninguém diz ter o 2♣ — a distribuição travou';

  @override
  String bootPlayer(String name) {
    return 'Expulsar $name';
  }

  @override
  String get cannotDealTitle => 'Este aparelho não consegue distribuir';

  @override
  String get cannotDealLabel => 'A distribuição parou de funcionar aqui';

  @override
  String cannotDealWhy(String reason) {
    return 'Por isso você saiu da mesa, e os outros seguem com um bot no seu lugar. Recarregar a página recomeça a distribuição. ($reason)';
  }

  @override
  String get connectionFailure => 'Falha de conexão';

  @override
  String get jurorQuorumLost => 'Júri sem quórum';

  @override
  String get jurorQuorumLostWhy =>
      'Poucos dos jurados que guardam os lugares dos bots ainda estão online, então a mão não pode continuar. A partida termina aqui, sem pontuação.';

  @override
  String get onWithIt => 'Continuar';

  @override
  String get home => 'Início';

  @override
  String hereCount(int here, int humans, String rated) {
    String _temp0 = intl.Intl.selectLogic(rated, {
      'rated': 'ranqueada',
      'other': 'não ranqueada',
    });
    return '$here de $humans aqui  ·  $_temp0';
  }

  @override
  String get botTookYourSeat => 'Um bot ficou com o seu lugar';

  @override
  String get tableCouldNotHear =>
      'A mesa não teve notícias suas e continuou sem você.';

  @override
  String get back => 'Voltar';

  @override
  String get waitingForJurors => 'Esperando o júri…';

  @override
  String get dealing => 'Distribuindo';

  @override
  String get dealingKeys => 'Distribuindo — chaves';

  @override
  String shuffling(int turn) {
    return 'Embaralhando ($turn de 4)';
  }

  @override
  String get dealingTheCards => 'Distribuindo as cartas';

  @override
  String get openingTheCards => 'Abrindo as cartas';

  @override
  String get gameEndsAt => 'A partida termina quando alguém chega a';

  @override
  String targetPoints(int target) {
    return '$target pontos';
  }

  @override
  String get ratedMovesRatings =>
      'Partidas ranqueadas mexem no seu rating, e no dos bots';

  @override
  String get rated => 'Ranqueada';

  @override
  String get unrated => 'Não ranqueada';

  @override
  String get sourceCode => 'Código';

  @override
  String get licenseName => 'Licença';

  @override
  String get build => 'Versão';

  @override
  String get published => 'Publicada';

  @override
  String get newBuildAvailable => 'Nova versão disponível';

  @override
  String get livePaused =>
      'O jogo ao vivo está pausado por enquanto. Jogar sozinho continua liberado.';

  @override
  String get updateDueWeb =>
      'Esta versão está desatualizada. Recarregue para pegar a nova.';

  @override
  String get updateDueApp =>
      'Esta versão está desatualizada. Atualize o app para pegar a nova.';

  @override
  String get reload => 'Recarregar';

  @override
  String get tellUsWhatsBroken => 'Conte o que está quebrado';

  @override
  String get feedbackIntro =>
      'O que aconteceu, e o que você esperava? Uma ou duas frases bastam.';

  @override
  String get feedbackHint => 'O que aconteceu';

  @override
  String get feedbackWithRecord =>
      'Enviar também o registro desta partida, para a mão poder ser repetida';

  @override
  String get feedbackSentWithIt => 'Vai junto';

  @override
  String get feedbackSend => 'Enviar';

  @override
  String get feedbackIsPublic =>
      'Isto abre uma issue no GitHub, que qualquer pessoa pode ler. Não inclua nada privado.';

  @override
  String get feedbackCopied => 'Copiado. Cole na página que abriu.';

  @override
  String feedbackCopiedTo(String to) {
    return 'Copiado. Cole em $to';
  }

  @override
  String statsRecent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Suas últimas $count partidas sozinho',
      one: 'Sua última partida sozinho',
    );
    return '$_temp0';
  }

  @override
  String statsRecentSpoken(int count, String scores, int average) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Pontuações finais das suas últimas $count partidas sozinho, da mais antiga para a mais recente: $scores. Média $average.',
      one:
          'Pontuação final da sua última partida sozinho: $scores. Média $average.',
    );
    return '$_temp0';
  }

  @override
  String statsAverage(int average) {
    return 'média $average';
  }

  @override
  String get statsLowerIsBetter =>
      'Pontuações finais, da mais antiga para a mais recente. Quanto menor, melhor.';

  @override
  String get statsQueens => 'Dama de espadas pega';

  @override
  String get statsMoonsShot => 'Luas atiradas';

  @override
  String get statsMoonsBlocked => 'Luas bloqueadas';

  @override
  String statsOverHands(int hands) {
    String _temp0 = intl.Intl.pluralLogic(
      hands,
      locale: localeName,
      other: 'Em $hands mãos sozinho',
      one: 'Em 1 mão sozinho',
    );
    return '$_temp0';
  }

  @override
  String seatWhere(String where) {
    String _temp0 = intl.Intl.selectLogic(where, {
      'left': 'à sua esquerda',
      'across': 'à sua frente',
      'other': 'à sua direita',
    });
    return ', $_temp0';
  }

  @override
  String takesPoints(String who, int points) {
    String _temp0 = intl.Intl.pluralLogic(
      points,
      locale: localeName,
      other: '$points pontos',
      one: '1 ponto',
    );
    return '$who, $_temp0';
  }

  @override
  String sheetRow(String name, int delta, int total) {
    return '$name: $delta nesta mão, $total na partida';
  }

  @override
  String get joinHouseholdTitle => 'Entrar nesta assinatura?';

  @override
  String get joinHouseholdBody =>
      'Este link adiciona este aparelho a uma assinatura de jogo ao vivo. Entre só se ele veio de você ou de alguém com quem você compartilha.';

  @override
  String get join => 'Entrar';

  @override
  String get notNow => 'Agora não';

  @override
  String get privacyPolicy => 'Política de privacidade';

  @override
  String get termsOfUse => 'Termos de uso';

  @override
  String get manageSubscription => 'Gerenciar assinatura';

  @override
  String get manageSubscriptionHint =>
      'Cancele, troque o cartão ou veja os recibos.';

  @override
  String get managedWhereBought =>
      'Esta assinatura é gerenciada onde foi comprada.';

  @override
  String get licenceNotForThisDevice =>
      'A resposta do serviço não era uma licença para este aparelho.';

  @override
  String get storeFailed =>
      'A loja não concluiu a compra. Tente de novo daqui a pouco.';

  @override
  String get nothingToRestore =>
      'Nenhuma assinatura para restaurar foi encontrada nesta conta da loja.';

  @override
  String get restorePurchases => 'Restaurar compras';

  @override
  String get storePending =>
      'A loja está esperando para aprovar o pagamento. O jogo ao vivo abre aqui assim que ela aprovar.';

  @override
  String storeRenewal(String price, String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'conta Apple',
      'other': 'conta Google',
    });
    String _temp1 = intl.Intl.selectLogic(store, {
      'apple': 'da App Store',
      'other': 'do Google Play',
    });
    return '$price por ano, cobrados na sua $_temp0 ao confirmar. Renova sozinha a cada ano até você cancelar, quando quiser, nas assinaturas $_temp1, pelo menos um dia antes da renovação.';
  }

  @override
  String manageInStore(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'na App Store',
      'other': 'no Google Play',
    });
    return 'Cancele ou altere $_temp0.';
  }

  @override
  String get subscription => 'Assinatura';

  @override
  String get finishingPurchase => 'Concluindo sua compra…';

  @override
  String get paidLiveSoon =>
      'Seu pagamento foi aprovado. O jogo ao vivo abre assim que chegar até nós — recarregue em um minuto.';

  @override
  String get checkingOnline => 'Procurando jogadores online…';

  @override
  String get activateSubscription => 'Ativar assinatura';

  @override
  String get activateBody =>
      'Traga este dispositivo para uma assinatura que você já tem. Escaneie o código que outro dispositivo seu mostra em Assinatura, ou digite ou cole um código: esse, ou um código de backup do e-mail.';

  @override
  String get code => 'Código';

  @override
  String get paste => 'Colar';

  @override
  String get scanCode => 'Escanear um código';

  @override
  String get activate => 'Ativar';

  @override
  String get activated => 'O jogo ao vivo está aberto neste dispositivo.';

  @override
  String get noCamera =>
      'Não há câmera para escanear aqui. Digite ou cole o código.';

  @override
  String get pointAtCode =>
      'Aponte a câmera para o código no seu outro dispositivo.';

  @override
  String get orTypeCode =>
      'Ou digite este código no outro dispositivo, em Ativar assinatura:';

  @override
  String get copy => 'Copiar';

  @override
  String get copied => 'Copiado';

  @override
  String get backupCodes => 'Códigos de backup';

  @override
  String get backupCodesHint =>
      'Para o dia em que nenhum dos seus dispositivos estiver à mão para mostrar um código. Cada um traz um dispositivo para esta assinatura, uma vez. Guarde-os num lugar seguro.';

  @override
  String get showBackupCodes => 'Mostrar códigos de backup';

  @override
  String get codeUsedMark => 'usado';

  @override
  String get replaceCodes => 'Substituir códigos';

  @override
  String get replaceCodesTitle => 'Substituir os códigos de backup?';

  @override
  String get replaceCodesBody =>
      'Estes cinco deixam de funcionar, e cinco novos tomam o seu lugar.';

  @override
  String get replace => 'Substituir';

  @override
  String get codesMade => 'Novos códigos criados.';

  @override
  String get emailCodes => 'Enviar por e-mail';

  @override
  String get codesSent => 'Enviados para o e-mail com que assinou.';

  @override
  String get codesNoAddress =>
      'Esta assinatura não tem um e-mail para onde enviá-los.';

  @override
  String get codesNotSent =>
      'Não foi possível enviá-los agora. Tente mais tarde.';

  @override
  String get haveACode => 'Tem um código? Ativar';

  @override
  String get privacyShort => 'Privacidade';

  @override
  String get termsShort => 'Termos';

  @override
  String get gameTitle => 'A partida';

  @override
  String get checkingGame => 'Verificando cada carta do jogo.';

  @override
  String get stillCheckingGame => 'Verificando o resto do jogo…';

  @override
  String get noGameHere =>
      'Não há nenhuma partida terminada guardada neste endereço.';

  @override
  String gameDoesNotCheck(String reason) {
    return 'O registo desta partida não é válido: $reason';
  }

  @override
  String get cantCheckGame =>
      'Este dispositivo não consegue verificar a distribuição, por isso não pode mostrar a partida.';

  @override
  String trickNumber(int trick) {
    return 'Vaza $trick';
  }

  @override
  String seatPlayer(int seat) {
    return 'Jogador $seat';
  }

  @override
  String get seeWholeGame => 'Ver a partida inteira';

  @override
  String get shareToWatch => 'Compartilhar link para assistir';

  @override
  String get liveNow => 'Ao vivo';

  @override
  String get watchingNote =>
      'As mãos ficam ocultas até o jogo acabar; então o jogo inteiro estará aqui, verificado.';

  @override
  String get passingNow => 'Passando cartas';

  @override
  String get dealingNow => 'Distribuindo';

  @override
  String toPlayNow(String name) {
    return 'Vez de $name';
  }

  @override
  String get yourAccount => 'Sua conta';

  @override
  String get signInToKeep =>
      'Entre com sua conta e, num celular novo ou num navegador que esqueceu este, você recupera a assinatura entrando do mesmo jeito. Da conta só se guarda uma forma embaralhada do número dela: nem nome, nem e-mail.';

  @override
  String get signInToBringBack =>
      'Já assina e entrou com sua conta naquele aparelho? Entre do mesmo jeito para trazer a assinatura para cá.';

  @override
  String signedInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Conectado com a Apple.',
      'other': 'Conectado com o Google.',
    });
    return '$_temp0 Entre do mesmo jeito num celular novo ou em outro navegador, e esta assinatura vai junto.';
  }

  @override
  String signedInBeforeBuying(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Conectado com a Apple.',
      'other': 'Conectado com o Google.',
    });
    return '$_temp0 Uma assinatura comprada aqui fica com a sua conta.';
  }

  @override
  String signInWith(String provider) {
    String _temp0 = intl.Intl.selectLogic(provider, {
      'apple': 'Entrar com a Apple',
      'other': 'Entrar com o Google',
    });
    return '$_temp0';
  }

  @override
  String get accountElsewhere =>
      'Essa conta está conectada em outro aparelho. Trazer para cá? Um aparelho novo então recupera esta assinatura, e o outro fica com o que tem.';

  @override
  String get moveAccountHere => 'Trazer para cá';

  @override
  String get signedIn => 'Conectado.';

  @override
  String get signedInNoSubscription =>
      'Conectado. Essa conta ainda não tem assinatura.';

  @override
  String get signInFailed =>
      'A entrada não terminou. Tente de novo daqui a pouco.';
}
