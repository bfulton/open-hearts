/// The table's clocks: the deadlines and silences after which a seat
/// proposes a transition the table settles — a boot, a held bot seat
/// given to the escrow, the game ended for a lost quorum, a hand dealt
/// with its bot seats in the open.
///
/// Every seat has to agree on them. A seat whose grace is shorter than
/// the others' proposes boots the others will not back, and one whose
/// jury deadline is longer backs nothing the others propose; either way
/// the table is held up on a question its seats answer differently. So
/// a table's timing is chosen once, by whoever starts it, from that
/// device's remote config (docs/06-service.md, "Remote config"), and
/// rides in the start event everyone signs, as the target does
/// ([TableSpec.timing]).
///
/// What is left out is pacing — how often something is said again, a
/// heartbeat, a carry, a top-up, how often a jury is proposed — and the
/// proposer's own choice of candidates for a jury: none of it decides
/// a state, and two seats pacing differently still agree about where
/// the table is (docs/07-states.md, "The clocks that stay").
library;

import 'time_bank.dart';

class TableTiming {
  const TableTiming({
    this.bank = TimeBank.standard,
    this.botActsMs = 15000,
    this.botDealsMs = 40000,
    this.quorumLostMs = 20000,
    this.silenceMs = 120000,
    this.jurorSilenceMs = 30000,
  });

  /// The timing every table had before a table could have its own, and
  /// still has unless the device that starts it is told otherwise.
  static const standard = TableTiming();

  /// A person's clock: a grace per decision, a bank per hand
  /// (time_bank.dart).
  final TimeBank bank;

  /// How long a bot seat's holder has to take the seat's turn, a card
  /// or the pass. A bot's move is worked out rather than thought
  /// about, so this is a deadline on a computation and not on a
  /// person: there is no grace in it and no bank behind it, which is
  /// what a person's seat gets instead.
  ///
  /// Fifteen seconds, measured on a slow machine rather than a fast
  /// one. It was three: over six seeded hands a held bot seat answered
  /// in 69 ms at the middle and 155 ms at the worst over a data
  /// channel, 365 ms and 787 ms with a relay's latency under it, and
  /// three was about four times the worst. On two cores shared by four
  /// browsers — a hosted runner, nearer a cheap phone than a desk is —
  /// a held pass took 4.3 s at the ninety-fifth percentile and a held
  /// card 8.7 at the worst, and a juror that was working missed the
  /// three in five runs of six there: its seat went to the escrow and
  /// it was left out of the next draw. Fifteen is three and a half
  /// times that 4.3, as a deal step's allowance is of its own, and 1.7
  /// times the worst card.
  final int botActsMs;

  /// And its deal steps. A deal step is slower and waits on more — a
  /// held seat's keys wait for the record to say which draw the hand is
  /// sealed to, and a step is checked against things that may not have
  /// arrived — and it answers at 2.9 s at the ninety-fifth percentile
  /// against a play's 0.16 on a machine with room to spare. A held seat
  /// that misses it goes to the escrow like one that misses a card, and
  /// a seat given up with deal steps still to take gives the hand up
  /// undealt.
  ///
  /// Forty seconds, measured on a slow machine rather than a fast one.
  /// It was ten, three and a half times that 2.9 s. On two cores
  /// shared by four browsers held seats' deal steps took 3.9 s at the
  /// middle, 11.7 at the ninety-fifth percentile and 24.9 at the worst
  /// of 187, one in eleven of them past ten; and a working juror that
  /// missed the ten cost its table the whole hand, twice in four runs.
  /// Forty is the same three and a half times, now of the slow
  /// machine's 11.7, and 1.6 times the worst it did. A juror gone
  /// quiet is still let go at [jurorSilenceMs]; this is only how long
  /// one still heard from may sit on a step.
  final int botDealsMs;

  /// How long a table stopped at a seat nobody left can open waits,
  /// saying so, before the game ends. Those who could open it have not
  /// been heard from for [jurorSilenceMs] by then, so the game ends no
  /// sooner than fifty seconds after the last of them was. It was two
  /// minutes, the silence a person is given, and that was two minutes
  /// of a stopped table in front of people who could do nothing about
  /// it.
  final int quorumLostMs;

  /// How long a person may be silent before a peer boots them at their
  /// turn without waiting on their clock (docs/04-live-play.md,
  /// "Leaving, through three doors"). Two minutes, longer than a bank a
  /// stalled seat empties in under one; it was thirty seconds, until a
  /// phone that switched apps for a moment came back to a bot in its
  /// seat.
  final int silenceMs;

  /// How long a juror may be silent before the table stops counting it
  /// as there: half a minute, after which its bot seat is the escrow's.
  final int jurorSilenceMs;

  /// The fields as a start event carries them, all in milliseconds.
  Map<String, int> toJson() => {
        'graceMs': bank.graceMs,
        'passGraceMs': bank.passGraceMs,
        'bankMs': bank.bankMs,
        'fixedMs': bank.fixedMs,
        'botActsMs': botActsMs,
        'botDealsMs': botDealsMs,
        'quorumLostMs': quorumLostMs,
        'silenceMs': silenceMs,
        'jurorSilenceMs': jurorSilenceMs,
      };

  /// What each field may be, in milliseconds, least and most. The
  /// worker checks a remote config's `table` against the same
  /// (service/functions/worker.mjs, `tableTimingOf`).
  static const bounds = {
    'graceMs': (2000, 60000),
    'passGraceMs': (2000, 120000),
    'bankMs': (10000, 300000),
    'fixedMs': (15000, 120000),
    'botActsMs': (5000, 60000),
    'botDealsMs': (15000, 120000),
    'quorumLostMs': (10000, 120000),
    'silenceMs': (30000, 600000),
    'jurorSilenceMs': (10000, 120000),
  };

  /// The timing [json] says, field by field, with the standard for any
  /// field it does not name — so a start event from a build that had
  /// no timing to say is the standard table.
  ///
  /// Every seat parses the same signed event and has to come out with
  /// the same clocks, so this is a function of [json] alone, and all or
  /// nothing: a field of the wrong type or outside its [bounds], and
  /// the whole timing is the standard. Clamping one field and keeping the rest would be as
  /// deterministic, but would make a table nobody chose. Names it does
  /// not know are passed over, for a later build's fields.
  static TableTiming parse(Object? json) {
    if (json == null) return standard;
    if (json is! Map) return standard;
    final at = standard.toJson();
    for (final MapEntry(:key, :value) in json.entries) {
      final range = bounds[key];
      if (range == null) continue;
      if (value is! int || value < range.$1 || value > range.$2) return standard;
      at[key as String] = value;
    }
    return TableTiming(
      bank: TimeBank(
        graceMs: at['graceMs']!,
        passGraceMs: at['passGraceMs']!,
        bankMs: at['bankMs']!,
        fixedMs: at['fixedMs']!,
      ),
      botActsMs: at['botActsMs']!,
      botDealsMs: at['botDealsMs']!,
      quorumLostMs: at['quorumLostMs']!,
      silenceMs: at['silenceMs']!,
      jurorSilenceMs: at['jurorSilenceMs']!,
    );
  }

  /// This timing with a person's clock of [bank]'s.
  TableTiming withBank(TimeBank bank) => TableTiming(
        bank: bank,
        botActsMs: botActsMs,
        botDealsMs: botDealsMs,
        quorumLostMs: quorumLostMs,
        silenceMs: silenceMs,
        jurorSilenceMs: jurorSilenceMs,
      );

  @override
  bool operator ==(Object other) {
    if (other is! TableTiming) return false;
    final a = toJson();
    final b = other.toJson();
    return a.keys.every((k) => a[k] == b[k]);
  }

  @override
  int get hashCode => Object.hashAll(toJson().values);

  @override
  String toString() => 'TableTiming(${toJson()})';
}
