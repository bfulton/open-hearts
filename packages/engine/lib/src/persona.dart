/// The bots, by name.
///
/// Every bot at a table is one of these, and the seat says so. They are
/// famous lovers — open hearts — and each has a temperament: a handful
/// of settings on the one policy in bot.dart, every one of which is a
/// choice a strong player might make. A character is allowed to be rash
/// or patient, never bad; test/persona_test.dart plays them against each
/// other and fails if any falls behind.
///
/// Nothing here is randomness. A persona is data, so a bot's play stays
/// a computable consequence of its cards (docs/04-live-play.md), and the
/// oblivious circuit in oblivious.dart takes the same settings as
/// constants.
library;

/// Which suit to lead from when there is no queen to flush.
enum LeadFrom {
  /// The shortest suit: cheap now, and a void soon.
  shortest,

  /// The longest suit, while it still has a genuinely low card to lead
  /// (a six or under). Those are the safest leads in the hand, and the
  /// short suits stay short for discarding into. Once the long suit has
  /// nothing low left, the shortest suit as usual.
  longestWhileLow,
}

/// What to do with the queen of spades in the pass. (What to do with a
/// short side suit is not a style: emptying it is simply right, by a
/// wide margin, and every persona does it — see [Persona.shortSuitWeight].)
///
/// Each style is a few numbers the pass scoring reads; the getters on
/// [Persona] spell them out so the bot and its circuit read the same
/// ones.
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
enum Pace {
  quick(400, 700),
  measured(600, 1100),
  slow(900, 1600);

  const Pace(this.minMs, this.maxMs);

  final int minMs;
  final int maxMs;
}

/// One bot's temperament. See [Persona.roster].
class Persona {
  const Persona({
    required this.name,
    required this.epithet,
    this.flushMinSmallSpades = 1,
    this.heartDumpRank = 10,
    this.moonDefenseTrigger = 4,
    this.passStyle = PassStyle.shedHeight,
    this.leadFrom = LeadFrom.shortest,
    this.pace = Pace.measured,
    this.shortSuitWeight = 20,
    this.shootLoserShare = 4,
    this.shootPassMaxLosers = 5,
    this.keepsStopper = true,
  });

  final String name;

  /// One line, in the table's voice, for the seat and the lobby.
  final String epithet;

  /// How many spades below the queen it takes before leading one to
  /// flush her out. A value above 13 means never.
  final int flushMinSmallSpades;

  /// Void in the led suit, a heart at least this high is thrown before
  /// any side-suit card.
  final int heartDumpRank;

  /// Points one opponent has to hold — all of them so far — before the
  /// bot starts taking tricks to break up the moon.
  final int moonDefenseTrigger;

  final PassStyle passStyle;
  final LeadFrom leadFrom;
  final Pace pace;

  /// Runs at the moon when at most one card in this many is a loser
  /// (`Bot.strength`); zero never runs. Four is a shot most strong
  /// players would take; three is a gambler's. Never running costs six
  /// points of tables, so everyone runs.
  final int shootLoserShare;

  /// Passes for a shot — the three lowest cards — when thirteen hold at
  /// most this many losers.
  final int shootPassMaxLosers;

  /// Holds on to the top heart, in the pass and when void, while no
  /// points are out: the one card that can stop a moon later.
  final bool keepsStopper;

  bool get shoots => shootLoserShare > 0;

  bool get flushesQueen => flushMinSmallSpades <= 13;

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
  static const westley = Persona(
    name: 'Westley',
    epithet: 'As you wish.',
  );

  static const buttercup = Persona(
    name: 'Buttercup',
    epithet: 'Ducks everything, and wins anyway.',
    flushMinSmallSpades: 2,
    heartDumpRank: 12,
    moonDefenseTrigger: 3,
    leadFrom: LeadFrom.longestWhileLow,
    pace: Pace.slow,
  );

  static const romeo = Persona(
    name: 'Romeo',
    epithet: "Can't hold a queen, or a heart, or his breath.",
    heartDumpRank: 8,
    passStyle: PassStyle.dumpQueen,
    pace: Pace.quick,
  );

  static const juliet = Persona(
    name: 'Juliet',
    epithet: 'Waits for the moment. Then it is yours.',
    flushMinSmallSpades: 2,
    heartDumpRank: 12,
    passStyle: PassStyle.keepQueen,
    pace: Pace.slow,
  );

  static const cyrano = Persona(
    name: 'Cyrano',
    epithet: 'The long suit, and the long game.',
    flushMinSmallSpades: 2,
    moonDefenseTrigger: 8,
    leadFrom: LeadFrom.longestWhileLow,
  );

  static const roxane = Persona(
    name: 'Roxane',
    epithet: 'Sees the moon coming before anyone.',
    flushMinSmallSpades: 2,
    moonDefenseTrigger: 3,
    leadFrom: LeadFrom.longestWhileLow,
  );

  static const casanova = Persona(
    name: 'Casanova',
    epithet: 'Keeps the queen close and the spades closer.',
    flushMinSmallSpades: 3,
    moonDefenseTrigger: 6,
    passStyle: PassStyle.keepQueen,
  );

  static const donJuan = Persona(
    name: 'Don Juan',
    epithet: 'Wants all of them, or none.',
    shootLoserShare: 3,
    shootPassMaxLosers: 7,
    pace: Pace.quick,
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
  ];

  /// The roster plus any character still being measured before it is
  /// let in.
  static const candidates = roster;

  static Persona named(String name) =>
      candidates.firstWhere((p) => p.name == name);
}
