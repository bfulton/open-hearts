/// Ratings, for people and for bots alike.
///
/// Glicko: a rating and a deviation, the deviation saying how much the
/// rating is worth. A game of Hearts is one rating period with three
/// opponents, scored pairwise by final total — the lower total wins
/// the pair, equal totals halve — so a fourth place against three
/// strong players costs less than against three weak ones, and a bot
/// is rated by the same arithmetic as a person, from the same results.
library;

import 'dart:math';

class Rating {
  const Rating({this.mu = 1500, this.phi = 350});

  /// A new player: 1500, with everything still to learn.
  static const fresh = Rating();

  /// The rating.
  final double mu;

  /// The deviation: 350 for a newcomer, settling towards [floor] with
  /// every game.
  final double phi;

  static const floor = 50.0;

  int get shown => mu.round();

  /// Wide enough that the number is not worth showing as settled.
  bool get provisional => phi > 150;

  @override
  String toString() => '$shown±${phi.round()}';
}

/// One opponent in a period, with the score against them: 1 for a win,
/// 0.5 for a tie, 0 for a loss.
typedef Outcome = ({Rating opponent, double score});

const _q = 0.0057565; // ln 10 / 400

double _g(double phi) => 1 / sqrt(1 + 3 * _q * _q * phi * phi / (pi * pi));

double _expected(Rating me, Rating them) => 1 / (1 + pow(10, -_g(them.phi) * (me.mu - them.mu) / 400));

/// The Glicko update for one period.
Rating rate(Rating me, List<Outcome> outcomes) {
  if (outcomes.isEmpty) return me;
  var d2inv = 0.0;
  var sum = 0.0;
  for (final o in outcomes) {
    final g = _g(o.opponent.phi);
    final e = _expected(me, o.opponent);
    d2inv += g * g * e * (1 - e);
    sum += g * (o.score - e);
  }
  d2inv *= _q * _q;
  final denominator = 1 / (me.phi * me.phi) + d2inv;
  final mu = me.mu + _q / denominator * sum;
  return Rating(mu: mu, phi: max(sqrt(1 / denominator), Rating.floor));
}

/// Pairwise scores for one seat in a finished game: lower total wins.
List<double> pairwise(int mine, List<int> others) =>
    [for (final t in others) mine < t ? 1.0 : (mine == t ? 0.5 : 0.0)];
