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
    // Fair share is a quarter. The floor is three and a third standard
    // errors under it, from each character's own number of seats (about
    // 1.5 points at eight hundred): with forty characters, one straying
    // that far by chance is a one-in-fifty run. The arena is seeded,
    // so a persona that trips it is weaker, not unlucky, and
    // tool/knobs.dart says which setting to blame; the mean score, far
    // less noisy, is held within six of the best.
    final standings = Arena.play(8000);
    final best = standings.map((s) => s.meanScore).reduce(min);
    for (final s in standings) {
      expect(s.seats, greaterThan(500), reason: '${s.persona} sat enough');
      final sigma = sqrt(0.25 * 0.75 / s.seats);
      expect(s.winRate, greaterThanOrEqualTo(0.25 - 3.3 * sigma),
          reason: '${s.persona} wins ${(100 * s.winRate).toStringAsFixed(1)}% of tables');
      expect(s.meanScore - best, lessThanOrEqualTo(6),
          reason: '${s.persona} averages ${s.meanScore.toStringAsFixed(1)} '
              'against a best of ${best.toStringAsFixed(1)}');
    }
  });

  test('a record kept under a persona\'s earlier name reads as that persona', () {
    expect(Persona.named('Sid'), same(Persona.tristan));
    expect(Persona.named('Nancy'), same(Persona.isolde));
    expect(Persona.named('Sid/3').name, 'Tristan');
  });
}
