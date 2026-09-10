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
    // Fair share is a quarter. With ~700 seats each the standard error
    // on a win rate is about 1.7 points, so a floor three points under
    // fair share is about two sigma; the arena is seeded, so a persona
    // that trips it is weaker, not unlucky, and tool/knobs.dart says
    // which setting to blame.
    final standings = Arena.play(1200);
    final best = standings.map((s) => s.meanScore).reduce(min);
    for (final s in standings) {
      expect(s.seats, greaterThan(500), reason: '${s.persona} sat enough');
      expect(s.winRate, greaterThanOrEqualTo(0.22),
          reason: '${s.persona} wins ${(100 * s.winRate).toStringAsFixed(1)}% of tables');
      expect(s.meanScore - best, lessThanOrEqualTo(6),
          reason: '${s.persona} averages ${s.meanScore.toStringAsFixed(1)} '
              'against a best of ${best.toStringAsFixed(1)}');
    }
  });
}
