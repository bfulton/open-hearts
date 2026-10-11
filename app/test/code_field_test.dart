// The code field's dashes (net/household.dart, CodeFormatter): put in as
// a backup code is typed or pasted, the cursor kept where it was among
// the code's own characters, backspace never stuck on a dash, and
// anything that is not a backup code left as it is.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/household.dart';

const formatter = CodeFormatter();

TextEditingValue at(String text, [int? cursor]) => TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor ?? text.length));

/// Types [chars] one at a time at the end, as a keyboard does.
TextEditingValue typed(String chars) {
  var value = const TextEditingValue();
  for (final c in chars.split('')) {
    value = formatter.formatEditUpdate(value, at(value.text + c));
  }
  return value;
}

void main() {
  test('a backup code in groups of four, as far as it has been typed', () {
    expect(codeAsTyped('n4d0'), 'N4D0');
    expect(codeAsTyped('n4d0c'), 'N4D0-C');
    expect(codeAsTyped('N4D0CG2NXXXZBXN9'), 'N4D0-CG2N-XXXZ-BXN9');
    expect(codeAsTyped('n4d0 cg2n-xxxz bxn9'), 'N4D0-CG2N-XXXZ-BXN9');
    // Not a backup code: left as it is.
    const hex = '0123456789abcdef0123456789abcdef';
    expect(codeAsTyped(hex), hex);
    const link = 'https://play.openhearts.game/?claim=0123';
    expect(codeAsTyped(link), link);
    expect(codeAsTyped(''), '');
  });

  test('typed one at a time: a dash after every four, the cursor at the end', () {
    final value = typed('N4D0CG2NXXXZBXN9');
    expect(value.text, 'N4D0-CG2N-XXXZ-BXN9');
    expect(value.selection.extentOffset, value.text.length);
    expect(typed('N4D0C').text, 'N4D0-C');
  });

  test('pasted whole, with or without dashes', () {
    final pasted = formatter.formatEditUpdate(const TextEditingValue(), at('n4d0cg2nxxxzbxn9'));
    expect(pasted.text, 'N4D0-CG2N-XXXZ-BXN9');
    expect(pasted.selection.extentOffset, pasted.text.length);
  });

  test('backspace over a dash takes the character before it', () {
    final old = at('N4D0-C');
    // The keyboard deletes the dash...
    final next = formatter.formatEditUpdate(at('N4D0-C', 5), at('N4D0C', 4));
    expect(next.text, 'N4DC', reason: 'the 0 gone, four left, so no dash');
    expect(next.selection.extentOffset, 3);
    // In a longer code the groups close up behind it.
    final longer = formatter.formatEditUpdate(at('N4D0-CG2N-X', 10), at('N4D0-CG2NX', 9));
    expect(longer.text, 'N4D0-CG2X');
    expect(longer.selection.extentOffset, 8);
    // ...and an ordinary backspace at the end takes the last character, and its dash.
    expect(formatter.formatEditUpdate(old, at('N4D0-')).text, 'N4D0');
  });

  test('a character put in the middle keeps the cursor after it', () {
    // N4D0-CG2N with the cursor after "N4", an X typed there.
    final next = formatter.formatEditUpdate(at('N4D0-CG2N', 2), at('N4XD0-CG2N', 3));
    expect(next.text, 'N4XD-0CG2-N');
    expect(next.selection.extentOffset, 3);
  });

  test("a device's code and a link are typed as they are", () {
    const hex = '0123456789abcdef0123456789abcdef';
    final value = formatter.formatEditUpdate(const TextEditingValue(), at(hex));
    expect(value.text, hex);
    const link = 'https://play.openhearts.game/?claim=0123-4567';
    final linked = formatter.formatEditUpdate(at(link), at('https://play.openhearts.game/?claim=01234567', 39));
    expect(linked.text, 'https://play.openhearts.game/?claim=01234567', reason: 'a dash deleted from a link is just deleted');
  });

  test('what the field shows is what codeIn reads', () {
    expect(codeIn(typed('N4D0CG2NXXXZBXN9').text), 'N4D0-CG2N-XXXZ-BXN9');
    expect(codeIn(typed('n4docg2nxxxzbxn9').text), 'N4D0-CG2N-XXXZ-BXN9', reason: 'an O read as the zero it looks like');
  });

  testWidgets('in a field: typing puts the dashes in', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: Material(child: TextField(controller: controller, inputFormatters: const [CodeFormatter()])),
    ));
    await tester.enterText(find.byType(TextField), 'abcd1234');
    expect(controller.text, 'ABCD-1234');
  });
}
