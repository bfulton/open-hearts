import 'dart:math';

import 'package:engine/engine.dart';
import 'package:test/test.dart';

void main() {
  test('every persona is distinct data with a name', () {
    final names = Persona.roster.map((p) => p.name).toSet();
    expect(names.length, Persona.roster.length);
    for (final p in Persona.roster) {
      expect(Persona.named(p.name), same(p));
      expect(p.epithet, isNotEmpty);
    }
    expect(Bot().persona, same(Persona.westley));
  });

  test('a character may be rash or patient, never bad', () {
    // Fair share is a quarter. With forty characters and ~800 seats
    // each the standard error on a win rate is about 1.5 points, so a
    // floor four points under fair share is about two and a half sigma
    // per character — and with forty of them, one straying that far by
    // chance is a one-in-twenty run. (Three points under, at two sigma,
    // tripped on a different innocent character every other run.) The
    // arena is seeded, so a persona that trips it is weaker, not
    // unlucky, and tool/knobs.dart says which setting to blame.
    final standings = Arena.play(8000);
    final best = standings.map((s) => s.meanScore).reduce(min);
    for (final s in standings) {
      expect(s.seats, greaterThan(500), reason: '${s.persona} sat enough');
      expect(s.winRate, greaterThanOrEqualTo(0.21),
          reason: '${s.persona} wins ${(100 * s.winRate).toStringAsFixed(1)}% of tables');
      expect(s.meanScore - best, lessThanOrEqualTo(6),
          reason: '${s.persona} averages ${s.meanScore.toStringAsFixed(1)} '
              'against a best of ${best.toStringAsFixed(1)}');
    }
  });
}
