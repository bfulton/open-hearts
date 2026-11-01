/// What this device does with the others' pictures: the viewer's own
/// list of pictures hidden and players blocked (lib/pictures.dart).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/pictures.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every picture shows until the viewer hides it', () {
    expect(Pictures().allows('bao'), isTrue);
  });

  test('a picture the viewer hid stays hidden, and is kept', () async {
    final p = Pictures();
    await p.hide('bao');
    expect(p.allows('bao'), isFalse);
    expect(p.allows('dee'), isTrue, reason: 'nobody else');

    final again = await Pictures.load();
    expect(again.isHidden('bao'), isTrue, reason: 'kept with the identity');
    await again.show('bao');
    expect(again.allows('bao'), isTrue);
    expect((await Pictures.load()).isHidden('bao'), isFalse);
  });

  test('a blocked player: no picture whatever it is, kept with the identity, until unblocked', () async {
    final p = Pictures();
    await p.block('bao');
    expect(p.isBlocked('bao'), isTrue);
    expect(p.allows('bao'), isFalse);
    expect(p.isHidden('bao'), isFalse, reason: 'blocking is its own choice, not hiding the picture');
    expect(p.allows('dee'), isTrue, reason: 'nobody else');

    final again = await Pictures.load();
    expect(again.isBlocked('bao'), isTrue, reason: 'kept with the identity');
    expect(again.allows('bao'), isFalse);
    await again.unblock('bao');
    expect(again.allows('bao'), isTrue);
    expect((await Pictures.load()).isBlocked('bao'), isFalse);
  });

  test('the list notifies, so the badges redraw', () async {
    final p = Pictures();
    var beats = 0;
    p.addListener(() => beats++);
    await p.hide('dee');
    expect(beats, 1);
    await p.show('dee');
    expect(beats, 2);
    await p.show('dee');
    expect(beats, 2, reason: 'nothing changed');
    await p.block('cy');
    expect(beats, 3);
    await p.unblock('cy');
    expect(beats, 4);
  });
}
