/// An avatar: what travels, what is kept, what shows.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/ui/player_icon.dart';

/// Scrolls to something and presses it. A tap at a point off the
/// screen lands on whatever is at that point, which is nothing, and
/// the test then reads as though the press did not take.
Future<void> reach(WidgetTester tester, Finder what) async {
  await tester.ensureVisible(what);
  await tester.pumpAndSettle();
  await tester.tap(what);
  await tester.pumpAndSettle();
}

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
    // Named in every language the app speaks: an icon the message has
    // no case for falls through to its last, and is called a snowflake.
    for (final words in [for (final l in AppLocalizations.supportedLocales) lookupAppLocalizations(l)]) {
      final names = {for (final key in AvatarIcons.all.keys) key: words.avatarIcon(key)};
      expect(names.values.toSet(), hasLength(names.length), reason: '${words.localeName}: every icon has a name of its own');
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

  test('a picture keeps none of what the camera wrote in it: not where it was taken', () {
    // A phone's photograph carries its EXIF through the picker, and the
    // picture goes to the relays for anyone to read (docs/launch/privacy.md).
    final photo = img.Image(width: 200, height: 200);
    img.fill(photo, color: img.ColorRgb8(200, 10, 10));
    photo.exif.gpsIfd.setGpsLocation(latitude: 48.8584, longitude: 2.2945);
    photo.exif.imageIfd.make = 'Phone';
    final taken = Uint8List.fromList(img.encodeJpg(photo));
    expect(img.decodeJpg(taken)!.exif.gpsIfd.gpsLatitude, isNotNull, reason: 'the photograph says where it was taken');
    for (final small in [shrinkPicture(taken), shrinkPicture(taken, from: const Rect.fromLTWH(20, 20, 120, 120))]) {
      final back = img.decodeJpg(small!)!;
      expect(back.exif.gpsIfd.gpsLatitude, isNull, reason: 'the picture does not');
      expect(back.exif.isEmpty, isTrue, reason: 'nor anything else the camera wrote');
    }
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

  testWidgets('the profile: a name, an icon, a colour, Done — and My initials clears it', (tester) async {
    // A phone, because the page is longer than a phone and what is
    // below the fold has to be scrolled to, here as there.
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Profile? picked;
    Profile current = (name: 'Ada', avatar: Avatar.none);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => picked = await showProfile(context, current: current, seed: 'k1'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The name is asked for here, and nowhere else.
    expect(find.widgetWithText(TextField, 'Your name'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Ada Lovelace');
    await tester.pumpAndSettle();
    expect(find.text('AL'), findsOneWidget, reason: 'the badge on the page wears what is typed');
    await reach(tester, find.bySemanticsLabel('Rocket'));
    await reach(tester, find.bySemanticsLabel('Colour 4'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(picked, (name: 'Ada Lovelace', avatar: const Avatar(icon: 'rocket', color: 3)));

    current = picked!;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await reach(tester, find.text('My initials'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(picked, (name: 'Ada Lovelace', avatar: Avatar.none), reason: 'the name it came in with, and no avatar');
  });
}
