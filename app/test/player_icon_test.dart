/// A player's icon: initials on a colour that is theirs, the same
/// wherever they appear.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/player_icon.dart';

void main() {
  test('initials: up to two, from the name', () {
    expect(PlayerIcon.initialsOf('Mumtaz Mahal'), 'MM');
    expect(PlayerIcon.initialsOf('Westley'), 'W');
    expect(PlayerIcon.initialsOf('You'), 'Y');
    expect(PlayerIcon.initialsOf('ada lovelace byron'), 'AL');
    expect(PlayerIcon.initialsOf('  '), '?');
  });

  test('the colour is the seed\'s, stable, and from the palette', () {
    final a = PlayerIcon.colorOf('f8d453' * 10);
    expect(PlayerIcon.colorOf('f8d453' * 10), a);
    expect(PlayerIcon.palette, contains(a));
    // Different seeds spread over the palette rather than piling up.
    final seen = {for (var i = 0; i < 200; i++) PlayerIcon.colorOf('seed-$i')};
    expect(seen.length, PlayerIcon.palette.length);
  });
}
