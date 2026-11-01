/// A player's icon: initials on a colour that is theirs, the same
/// wherever they appear.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
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

  testWidgets('a picture is decoded no bigger than one the app makes, whatever size it says it is', (tester) async {
    final picture = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    await tester.pumpWidget(PlayerIcon(name: 'Ada', seed: 'a', avatar: Avatar(picture: picture), size: 40));
    final image = tester.widget<Image>(find.byType(Image)).image;
    expect(image, isA<ResizeImage>());
    final resized = image as ResizeImage;
    expect((resized.width, resized.height, resized.policy), (Avatar.side, Avatar.side, ResizeImagePolicy.fit));
  });
}
