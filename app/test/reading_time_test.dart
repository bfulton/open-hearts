import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/reading_time.dart';

void main() {
  test('a glance for a word, reading time for a sentence, and never for ever', () {
    expect(readingTime('Copied.'), const Duration(milliseconds: 1850));
    expect(readingTime('This subscription has no email to send them to.').inMilliseconds, inInclusiveRange(3500, 4500));
    expect(readingTime('x' * 500), const Duration(seconds: 6));
    expect(readingTime(''), const Duration(milliseconds: 1800));
  });
}
