/// An avatar: what travels, what is kept, what shows.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/live/avatar_picker.dart';
import 'package:open_hearts/ui/player_icon.dart';

void main() {
  test('to the wire and back: icon and colour in a beat, the picture too when asked', () {
    final picture = Uint8List.fromList(List.generate(300, (i) => i % 251));
    final a = Avatar(icon: 'rocket', color: 3, picture: picture);
    expect(Avatar.fromJson(a.toJson()), a);
    final light = a.toJson(withPicture: false);
    expect(light.containsKey('picture'), isFalse);
    expect(Avatar.fromJson(light), const Avatar(icon: 'rocket', color: 3));
    expect(Avatar.fromJson(jsonDecode(jsonEncode(a.toJson()))), a, reason: 'through JSON text');
    expect(Avatar.fromJson(null), Avatar.none);
    expect(Avatar.fromJson({'icon': 'nonsense', 'color': 99, 'picture': 'not base64!'}), Avatar.none, reason: 'unknown is none');
    expect(Avatar.fromJson({'picture': base64Encode(Uint8List(Avatar.maxPictureBytes + 1))}).picture, isNull, reason: 'too heavy for a relay');
    expect(Avatar.none.isDefault, isTrue);
    expect(const Avatar(color: 1).isDefault, isFalse);
  });

  test('a bot looks the same at every table, and every icon is named', () {
    expect(Avatar.forBot('Westley'), Avatar.forBot('Westley'));
    expect(Avatar.forBot('Westley').icon, isNotNull);
    expect(Avatar.forBot('Westley'), isNot(Avatar.forBot('Buttercup')));
    for (final key in AvatarIcons.all.keys) {
      expect(AvatarIcons.names[key], isNotNull, reason: '$key has a name');
    }
    expect(AvatarIcons.all.length, greaterThanOrEqualTo(20));
  });

  test('a picture is shrunk to the middle square, sixty-four pixels, a few kilobytes', () {
    // A wide picture with a red middle: the crop keeps the middle.
    final wide = img.Image(width: 300, height: 100);
    img.fill(wide, color: img.ColorRgb8(0, 0, 255));
    img.fillRect(wide, x1: 100, y1: 0, x2: 199, y2: 99, color: img.ColorRgb8(255, 0, 0));
    final small = shrinkPicture(Uint8List.fromList(img.encodePng(wide)));
    expect(small, isNotNull);
    expect(small!.length, lessThanOrEqualTo(Avatar.maxPictureBytes));
    final back = img.decodeJpg(small)!;
    expect(back.width, Avatar.side);
    expect(back.height, Avatar.side);
    final centre = back.getPixel(32, 32);
    expect(centre.r, greaterThan(200), reason: 'the middle of the picture, red');
    expect(centre.b, lessThan(60));
    expect(shrinkPicture(Uint8List.fromList([1, 2, 3])), isNull, reason: 'not a picture');
  });

  testWidgets('what shows: the picture over the icon, the icon over the initials', (tester) async {
    final square = img.Image(width: 8, height: 8);
    img.fill(square, color: img.ColorRgb8(10, 200, 10));
    final picture = Uint8List.fromList(img.encodeJpg(square));
    await tester.pumpWidget(MaterialApp(
      home: Row(children: [
        PlayerIcon(name: 'Ada Lovelace', seed: 'k1'),
        PlayerIcon(name: 'Ada Lovelace', seed: 'k1', avatar: const Avatar(icon: 'rocket', color: 2)),
        PlayerIcon(name: 'Ada Lovelace', seed: 'k1', avatar: Avatar(icon: 'rocket', picture: picture)),
      ]),
    ));
    await tester.pump();
    expect(find.text('AL'), findsOneWidget, reason: 'initials with nothing chosen');
    expect(find.byIcon(AvatarIcons.all['rocket']!), findsOneWidget, reason: 'the icon when chosen, unless a picture is');
    expect(find.byType(Image), findsOneWidget);
    final icons = tester.widgetList<PlayerIcon>(find.byType(PlayerIcon)).toList();
    expect(icons[0].color, PlayerIcon.colorOf('k1'));
    expect(icons[1].color, PlayerIcon.palette[2]);
  });

  testWidgets('the picker: an icon, a colour, Done — and My initials clears it', (tester) async {
    Avatar? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => picked = await showAvatarPicker(context, current: Avatar.none, name: 'Ada', seed: 'k1'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Your avatar'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Rocket'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Colour 4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(picked, const Avatar(icon: 'rocket', color: 3));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Rocket'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My initials'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(picked, Avatar.none);
  });
}
