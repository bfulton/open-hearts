/// The bots, by name.
///
/// Every bot at a table is one of these, and the seat says so. They are
/// famous lovers — open hearts — and each has a temperament: a handful
/// of settings on the one policy in bot.dart, every one of which is a
/// choice a strong player might make. A character is allowed to be rash
/// or patient, never bad; test/persona_test.dart plays them against each
/// other and fails if any falls behind.
///
/// Each character also comes at every strength on a ladder ([at]), so
/// a person is seated with bots near their own rating, and a bot's
/// rating means what a person's does.
///
/// Nothing here is randomness. A persona is data, so a bot's play stays
/// a computable consequence of its cards (docs/04-live-play.md).
library;

/// What to do with the queen of spades in the pass. (What to do with a
/// short side suit is not a style: emptying it is simply right, by a
/// wide margin, and every persona does it — see [Persona.shortSuitWeight].)
///
/// Each style is a few numbers the pass scoring reads; the getters on
/// [Persona] spell them out.
enum PassStyle {
  /// The queen goes unless five spades stand behind her, and then she
  /// is worth about as much as a middling heart.
  shedHeight,

  /// Hold the queen behind spades whenever four can duck for her, and
  /// pass the height elsewhere.
  keepQueen,

  /// The queen goes, always, whatever is behind her.
  dumpQueen,
}

/// How long a bot appears to think. Rhythm, not strategy: the engine
/// decides instantly and the table waits this long before showing it.
/// A person's own pace is a different thing and lives in packages/table
/// (pace.dart): that one is measured, this one is manners.
enum BotPace {
  quick(400, 700),
  measured(600, 1100),
  slow(900, 1600);

  const BotPace(this.minMs, this.maxMs);

  final int minMs;
  final int maxMs;
}

/// One bot's temperament, at a strength. See [Persona.roster] and
/// [Persona.at].
class Persona {
  const Persona({
    required this.name,
    required this.epithet,
    this.level = top,
    this.flushMinSmallSpades = 1,
    this.moonDefenseTrigger = 4,
    this.passStyle = PassStyle.shedHeight,
    this.pace = BotPace.measured,
    this.shortSuitWeight = 20,
    this.shootLoserShare = 4,
    this.shootPassMaxLosers = 5,
    this.firstTrickHigh = true,
    this.queenAloneIsSafe = true,
    this.dumpsHearts = true,
    this.ducksHigh = true,
    this.takesHigh = true,
    this.discardsPoints = true,
    this.passesShape = true,
  });

  final String name;

  // ---- the ladder ------------------------------------------------------

  /// How many strengths a persona comes in. [top] is the whole policy;
  /// each step down takes away one thing a player learns, in the order
  /// [at] gives, so a character at every rating plays like a person at
  /// that rating — worse at the game, never absurd.
  static const levels = 9;
  static const top = levels - 1;

  /// This persona's strength, 0 to [top].
  final int level;

  /// The identity a rating attaches to: the name at the top, else
  /// `name/level`. [named] reads either.
  String get id => level == top ? name : '$name/$level';

  /// This persona at [level]: the same temperament, with the habits a
  /// player picks up removed from the top down, in about the order
  /// people learn them. Level 0 has none of them: it passes its three
  /// highest cards, leads its lowest, follows with its lowest and
  /// throws its highest when void — a first game, played by the rules.
  /// Each rung adds one thing. What each is worth is measured by
  /// packages/table/tool/ladder.dart, which is where [priors] come
  /// from, and by tool/knobs.dart one rung at a time.
  Persona at(int level) {
    final l = level.clamp(0, top);
    return Persona(
      name: name,
      epithet: epithet,
      level: l,
      // 8: runs at the moon. The character itself.
      shootLoserShare: l >= 8 ? shootLoserShare : 0,
      shootPassMaxLosers: shootPassMaxLosers,
      // 7: throws the top club on the pointless first trick.
      firstTrickHigh: l >= 7,
      // 6: void, throws a heart before a side card.
      dumpsHearts: l >= 6,
      // 5: leads small spades to flush the queen.
      flushMinSmallSpades: l >= 5 ? flushMinSmallSpades : 99,
      // 4: passes by the shape of the hand, not just by height.
      passesShape: l >= 4,
      passStyle: passStyle,
      shortSuitWeight: shortSuitWeight,
      // 3: void, throws the queen and the hearts before anything else.
      discardsPoints: l >= 3,
      // 2: last to play and taking the trick anyway, throws the top card.
      takesHigh: l >= 2,
      // 1: ducks as high as it can instead of as low.
      ducksHigh: l >= 1,
      // Every rung breaks up a run at the moon: see [moonDefenseTrigger].
      moonDefenseTrigger: moonDefenseTrigger,
      queenAloneIsSafe: queenAloneIsSafe,
      pace: pace,
    );
  }

  /// Every persona at every level.
  static List<Persona> get all => [
    for (final p in roster)
      for (var l = 0; l < levels; l++) p.at(l),
  ];

  /// The rating a persona at [level] starts from, before it has any
  /// results of its own: the ladder as calibrated in the arena
  /// (packages/table/tool/ladder.dart), anchored so the top is 1500.
  static int priorRating(int level) => priors[level.clamp(0, top)];

  /// From a run of twenty thousand tables, each a random four from the
  /// ladder at nearby rungs, fitted by Bradley–Terry (the model behind
  /// a rating's expected score) to two or three points a rung, over
  /// games to fifty. The whole ladder spans about 170 points: a first
  /// game finishes ahead of the character itself in a little over one
  /// pair in four. The middle half of the characters at one rung sit
  /// within about thirty points of each other. Shorter games are
  /// noisier, which closes the ladder up: over games to a hundred it
  /// spans about 240.
  static const priors = [1329, 1353, 1365, 1387, 1415, 1431, 1469, 1478, 1500];

  /// One line, in the table's voice, for the seat and the lobby.
  final String epithet;

  /// How many spades below the queen it takes before leading one to
  /// flush her out. A value above 13 means never.
  final int flushMinSmallSpades;

  /// Points one opponent has to hold — all of them so far — before the
  /// bot starts taking tricks to break up the moon. Any trigger from six
  /// to fourteen plays the same tables (tool/knobs.dart); three and four
  /// fire on a stray trick now and then, and cost a third of a point.
  /// Never defending wins a point a game at a table of bots that do,
  /// and loses three at a table of bots that don't, and seven against
  /// three players who run at every chance — which is what a person
  /// does to a table that never defends, and what would make a table of
  /// bots a rating pump. So every character defends, at every rung of
  /// the ladder.
  final int moonDefenseTrigger;

  final PassStyle passStyle;

  final BotPace pace;

  /// Runs at the moon when at most one card in this many is a loser
  /// (`Bot.strength`); zero never runs. Four is a shot most strong
  /// players would take; three is a gambler's. Never running costs six
  /// points of tables, so everyone runs.
  final int shootLoserShare;

  /// Passes for a shot — the three lowest cards — when thirteen hold at
  /// most this many losers.
  final int shootPassMaxLosers;

  // ---- what every persona does at the top, and stops doing on the
  // ---- way down the ladder (measured rules, not styles) ---------------

  /// Throws the highest club on the first trick, where no point can fall.
  final bool firstTrickHigh;

  /// Does not take points to break up a "run" that is exactly thirteen
  /// with the queen out — somebody caught with her, not collecting.
  final bool queenAloneIsSafe;

  /// Void in the led suit, throws a heart, any heart, before a side-suit
  /// card.
  final bool dumpsHearts;

  /// Following suit under the trick, throws the highest card that still
  /// ducks, the queen ahead of any; without this, the lowest card, every
  /// time, and the high ones wait in hand for the tricks that hurt.
  final bool ducksHigh;

  /// Last to play with nothing that ducks, throws the top card, since the
  /// trick is taken anyway (the lowest winner instead when it is spades
  /// with the queen still out); without this, the lowest card.
  final bool takesHigh;

  /// Void, throws the queen, the spades above her, the hearts, and only
  /// then the side suits; without this, the highest card held.
  final bool discardsPoints;

  /// Passes by the shape of the hand — the spade problem first, hearts
  /// weighted up, short suits away whole; without this, the three
  /// highest cards by rank.
  final bool passesShape;

  bool get shoots => shootLoserShare > 0;

  // ---- what the pass style means in numbers ---------------------------

  /// Spades in hand before the queen counts as protected. Above 13 means
  /// she never is.
  int get queenProtectedAt => switch (passStyle) {
    PassStyle.keepQueen => 4,
    PassStyle.dumpQueen => 99,
    _ => 5,
  };

  /// The queen's urgency to leave when she is protected; 100 when not.
  int get queenKeptDanger => switch (passStyle) {
    PassStyle.keepQueen => 20,
    _ => 30,
  };

  /// Spades below the queen that make A♠/K♠ survivable. Above 13 means
  /// they never are.
  int get highSpadesCoveredAt => switch (passStyle) {
    PassStyle.keepQueen => 2,
    PassStyle.dumpQueen => 99,
    _ => 3,
  };

  /// Danger added to a clubs or diamonds card per card its suit is short
  /// of four. At twenty a two- or three-card side suit goes whole ahead
  /// of anything but an unprotected queen, which is what tool/knobs.dart
  /// found wins: against a weight of three it takes a third of tables
  /// instead of a quarter, and the curve is still rising past thirty.
  /// Every persona plays it, so it is a field only so the tool can vary
  /// it.
  final int shortSuitWeight;

  @override
  String toString() => name;

  // ---- the roster ----------------------------------------------------

  /// The baseline: every setting at its plainest. `Bot()` with no
  /// persona plays as Westley.
  static const westley = Persona(name: 'Westley', epithet: 'As you wish.');

  static const buttercup = Persona(
    name: 'Buttercup',
    epithet: 'Ducks everything, and wins anyway.',
    moonDefenseTrigger: 3,
    pace: BotPace.slow,
  );

  static const romeo = Persona(
    name: 'Romeo',
    epithet: "Can't hold a queen, or a heart, or his breath.",
    passStyle: PassStyle.dumpQueen,
    pace: BotPace.quick,
  );

  static const juliet = Persona(
    name: 'Juliet',
    epithet: 'Waits for the moment. Then it is yours.',
    passStyle: PassStyle.keepQueen,
    pace: BotPace.slow,
  );

  static const cyrano = Persona(
    name: 'Cyrano',
    epithet: 'Lets a run go a long way before spoiling it.',
    moonDefenseTrigger: 8,
  );

  static const roxane = Persona(
    name: 'Roxane',
    epithet: 'Sees the moon coming before anyone.',
    moonDefenseTrigger: 3,
  );

  static const casanova = Persona(
    name: 'Casanova',
    epithet: 'Keeps the queen close and the spades closer.',
    moonDefenseTrigger: 6,
    passStyle: PassStyle.keepQueen,
  );

  static const donJuan = Persona(
    name: 'Don Juan',
    epithet: 'Wants all of them, or none.',
    shootLoserShare: 3,
    shootPassMaxLosers: 7,
    pace: BotPace.quick,
  );

  static const paolo = Persona(
    name: 'Paolo',
    epithet: 'Reads to the end of the page before he moves.',
    moonDefenseTrigger: 10,
    pace: BotPace.slow,
  );

  static const francesca = Persona(
    name: 'Francesca',
    epithet: 'Blames the book, and keeps the queen.',
    passStyle: PassStyle.keepQueen,
  );

  static const lancelot = Persona(
    name: 'Lancelot',
    epithet: 'Charges when the odds are merely good.',
    shootLoserShare: 3,
    shootPassMaxLosers: 6,
    pace: BotPace.quick,
  );

  static const guinevere = Persona(
    name: 'Guinevere',
    epithet: 'Sends the queen away before anyone asks.',
    moonDefenseTrigger: 3,
    passStyle: PassStyle.dumpQueen,
    pace: BotPace.slow,
  );

  static const aragorn = Persona(
    name: 'Aragorn',
    epithet: 'Waits for the moment, then takes the field.',
    moonDefenseTrigger: 6,
    shootPassMaxLosers: 6,
  );

  static const arwen = Persona(
    name: 'Arwen',
    epithet: 'Gives up the queen slowly, and only once.',
    pace: BotPace.slow,
  );

  static const orpheus = Persona(
    name: 'Orpheus',
    epithet: 'Holds the queen, looks back, loses her.',
    passStyle: PassStyle.keepQueen,
    moonDefenseTrigger: 8,
  );

  static const eurydice = Persona(
    name: 'Eurydice',
    epithet: 'Gone before the second trick.',
    passStyle: PassStyle.dumpQueen,
    pace: BotPace.quick,
  );

  static const markAntony = Persona(
    name: 'Mark Antony',
    epithet: 'Bets the empire on one hand.',
    shootLoserShare: 3,
    shootPassMaxLosers: 7,
    pace: BotPace.quick,
  );

  static const cleopatra = Persona(
    name: 'Cleopatra',
    epithet: 'The queen stays until she chooses to go.',
    passStyle: PassStyle.keepQueen,
    moonDefenseTrigger: 6,
    pace: BotPace.slow,
  );

  static const shahJahan = Persona(
    name: 'Shah Jahan',
    epithet: 'Builds the long game one careful trick at a time.',
    moonDefenseTrigger: 10,
    pace: BotPace.slow,
  );

  static const mumtazMahal = Persona(
    name: 'Mumtaz Mahal',
    epithet: 'Sees a run coming from the first heart.',
    moonDefenseTrigger: 3,
  );

  static const marieCurie = Persona(
    name: 'Marie Curie',
    epithet: 'Runs at the moon only when the numbers say so.',
    shootPassMaxLosers: 4,
  );

  static const pierreCurie = Persona(
    name: 'Pierre Curie',
    epithet: 'Patient, exact, and rarely caught with the queen.',
    moonDefenseTrigger: 6,
    pace: BotPace.slow,
  );

  static const bonnie = Persona(
    name: 'Bonnie',
    epithet: 'Runs at the moon with the lights on.',
    shootLoserShare: 3,
    shootPassMaxLosers: 7,
    pace: BotPace.quick,
  );

  static const clyde = Persona(
    name: 'Clyde',
    epithet: 'Drives the getaway, whatever the odds.',
    shootLoserShare: 3,
    shootPassMaxLosers: 6,
    moonDefenseTrigger: 8,
    pace: BotPace.quick,
  );

  static const diegoRivera = Persona(
    name: 'Diego Rivera',
    epithet: 'Works on a big wall, slowly.',
    moonDefenseTrigger: 10,
    pace: BotPace.slow,
  );

  static const fridaKahlo = Persona(
    name: 'Frida Kahlo',
    epithet: 'Keeps the queen, and paints her.',
    passStyle: PassStyle.keepQueen,
  );

  static const tristan = Persona(
    name: 'Tristan',
    epithet: 'Throws everything, all at once.',
    passStyle: PassStyle.dumpQueen,
    shootLoserShare: 3,
    shootPassMaxLosers: 7,
    pace: BotPace.quick,
  );

  static const isolde = Persona(
    name: 'Isolde',
    epithet: 'Wants the queen gone yesterday.',
    passStyle: PassStyle.dumpQueen,
    moonDefenseTrigger: 3,
    pace: BotPace.quick,
  );

  static const han = Persona(
    name: 'Han',
    epithet: 'Never tell him the odds.',
    shootPassMaxLosers: 7,
    pace: BotPace.quick,
  );

  static const leia = Persona(
    name: 'Leia',
    epithet: 'Holds the queen, holds the line.',
    passStyle: PassStyle.keepQueen,
    moonDefenseTrigger: 6,
  );

  static const heathcliff = Persona(
    name: 'Heathcliff',
    epithet: "Takes it all, or ruins everyone's evening.",
    shootPassMaxLosers: 6,
    moonDefenseTrigger: 3,
  );

  static const catherine = Persona(
    name: 'Catherine',
    epithet: 'Feels the moon coming in her bones.',
    moonDefenseTrigger: 3,
    pace: BotPace.slow,
  );

  static const darcy = Persona(
    name: 'Darcy',
    epithet: 'Too proud to give up a queen.',
    passStyle: PassStyle.keepQueen,
    moonDefenseTrigger: 8,
    pace: BotPace.slow,
  );

  static const elizabeth = Persona(
    name: 'Elizabeth',
    epithet: 'Reads the whole table, then passes lightly.',
    moonDefenseTrigger: 6,
  );

  static const cupid = Persona(
    name: 'Cupid',
    epithet: 'Aims high, and now and then hits.',
    shootPassMaxLosers: 7,
    moonDefenseTrigger: 4,
    pace: BotPace.quick,
  );

  static const psyche = Persona(
    name: 'Psyche',
    epithet: 'Trusts everyone until the lamp is lit.',
    moonDefenseTrigger: 10,
    pace: BotPace.slow,
  );

  static const dimitri = Persona(
    name: 'Dimitri',
    epithet: 'All in, on every hand that might be it.',
    shootLoserShare: 3,
    shootPassMaxLosers: 7,
    pace: BotPace.quick,
  );

  static const grushenka = Persona(
    name: 'Grushenka',
    epithet: 'Keeps the queen, and everyone guessing.',
    passStyle: PassStyle.keepQueen,
    moonDefenseTrigger: 3,
    pace: BotPace.slow,
  );

  static const pip = Persona(
    name: 'Pip',
    epithet: 'Gets rid of the queen, and has expectations.',
    passStyle: PassStyle.dumpQueen,
    moonDefenseTrigger: 6,
  );

  static const estella = Persona(
    name: 'Estella',
    epithet: 'Cold to the run until it is nearly done.',
    passStyle: PassStyle.keepQueen,
    moonDefenseTrigger: 10,
    pace: BotPace.slow,
  );

  /// Everyone who might sit down. Order is not rank.
  static const roster = [
    westley,
    buttercup,
    romeo,
    juliet,
    cyrano,
    roxane,
    casanova,
    donJuan,
    paolo,
    francesca,
    lancelot,
    guinevere,
    aragorn,
    arwen,
    orpheus,
    eurydice,
    markAntony,
    cleopatra,
    shahJahan,
    mumtazMahal,
    marieCurie,
    pierreCurie,
    bonnie,
    clyde,
    diegoRivera,
    fridaKahlo,
    tristan,
    isolde,
    han,
    leia,
    heathcliff,
    catherine,
    darcy,
    elizabeth,
    cupid,
    psyche,
    dimitri,
    grushenka,
    pip,
    estella,
  ];

  /// The roster plus any character still being measured before it is
  /// let in.
  static const candidates = roster;

  /// A persona by [id]: a name, or `name/level`.
  static Persona named(String id) {
    final slash = id.indexOf('/');
    final name = slash < 0 ? id : id.substring(0, slash);
    final persona = candidates.firstWhere((p) => p.name == (_renamed[name] ?? name));
    return slash < 0 ? persona : persona.at(int.parse(id.substring(slash + 1)));
  }

  /// Names a persona had before, as records already kept may carry them.
  static const _renamed = {'Sid': 'Tristan', 'Nancy': 'Isolde'};
}
