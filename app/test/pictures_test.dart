/// What this device does with the others' pictures: the viewer's own
/// list, and a check that fails open (lib/pictures.dart).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/pictures.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _picture = Uint8List.fromList(List.generate(64, (i) => i));
final _other = Uint8List.fromList(List.generate(64, (i) => 255 - i));

class _Says extends PictureCheck {
  _Says(this.answer, {this.ready = true});
  final bool? answer;
  int asked = 0;

  /// A model still coming down the wire.
  @override
  bool ready;

  @override
  Future<bool?> flagged(Uint8List jpeg) async {
    asked++;
    return answer;
  }
}

class _Throws extends PictureCheck {
  @override
  Future<bool?> flagged(Uint8List jpeg) async => throw StateError('no model');
}

/// A check with its model still arriving, and an answer the test holds.
class _Waits extends PictureCheck {
  @override
  bool ready = false;
  final answer = Completer<bool?>();
  @override
  Future<bool?> flagged(Uint8List jpeg) => answer.future;
}

class _Never extends PictureCheck {
  @override
  Future<bool?> flagged(Uint8List jpeg) => Completer<bool?>().future;
}

/// The first answer lands a microtask later; a picture is drawn as
/// whatever the policy says at the moment it is drawn.
Future<void> settled() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('with no check at hand every picture shows', () async {
    final p = Pictures();
    expect(p.allows('bao', _picture), isTrue);
  });

  test('a flagged picture is kept off, and the viewer can still ask for it', () async {
    final check = _Says(true);
    final p = Pictures(check: check);
    expect(p.allows('bao', _picture), isFalse, reason: 'held while the check runs');
    await settled();
    expect(p.allows('bao', _picture), isFalse);
    expect(p.wasFlagged('bao', _picture), isTrue);
    await p.show('bao');
    expect(p.allows('bao', _picture), isTrue);
    expect(p.wasFlagged('bao', _picture), isFalse);
  });

  test('a check that says no, says nothing, or throws lets the picture through', () async {
    for (final check in [_Says(false), _Says(null), _Throws()]) {
      final p = Pictures(check: check);
      p.allows('bao', _picture);
      await settled();
      expect(p.allows('bao', _picture), isTrue, reason: '${check.runtimeType} is not a flag');
      expect(p.wasFlagged('bao', _picture), isFalse);
    }
  });

  test('an answer that never comes shows the picture once the grace is spent', () async {
    final p = Pictures(check: _Never(), grace: const Duration(milliseconds: 30));
    expect(p.allows('bao', _picture), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(p.allows('bao', _picture), isTrue);
  });

  test('a check that cannot answer yet holds nothing up, and takes the picture back', () async {
    final check = _Says(true, ready: false);
    final p = Pictures(check: check);
    expect(p.allows('bao', _picture), isTrue, reason: 'the model is still arriving: show it');
    await settled();
    expect(p.allows('bao', _picture), isFalse, reason: 'and take it back when the answer lands');
    expect(p.wasFlagged('bao', _picture), isTrue);
  });

  test('a picture already drawn is never held for a second opinion, only taken back', () async {
    // The model lands mid-game, with pictures already on the table and
    // the answer about this one still to come.
    final check = _Waits();
    final p = Pictures(check: check);
    expect(p.allows('bao', _picture), isTrue, reason: 'nothing to ask yet');
    check.ready = true;
    expect(p.allows('bao', _picture), isTrue, reason: 'no blink now that there is');
    check.answer.complete(true);
    await settled();
    expect(p.allows('bao', _picture), isFalse, reason: 'taken back on the answer');
  });

  test('the bytes are read once, however many badges they land on', () async {
    final check = _Says(false);
    final p = Pictures(check: check);
    p.allows('bao', _picture);
    await settled();
    p.allows('bao', _picture);
    p.allows('dee', _picture);
    await settled();
    expect(check.asked, 1);
    p.allows('dee', _other);
    await settled();
    expect(check.asked, 2, reason: 'other bytes are another question');
  });

  test('a picture the viewer hid stays hidden, whatever the check says, and is kept', () async {
    final p = Pictures(check: _Says(false));
    await p.hide('bao');
    expect(p.allows('bao', _picture), isFalse);
    expect(p.wasFlagged('bao', _picture), isFalse, reason: 'their decision, not the check\'s');
    // A new picture from the same person is hidden too.
    expect(p.allows('bao', _other), isFalse);

    final again = await Pictures.load(check: _Says(false));
    expect(again.isHidden('bao'), isTrue, reason: 'kept with the identity');
    await again.show('bao');
    expect((await Pictures.load()).isHidden('bao'), isFalse);
  });

  test('the list notifies, so the badges redraw', () async {
    final p = Pictures(check: _Says(true));
    var beats = 0;
    p.addListener(() => beats++);
    p.allows('bao', _picture);
    await settled();
    expect(beats, greaterThan(0), reason: 'the verdict landed');
    await p.hide('dee');
    expect(beats, greaterThan(1));
  });
}
