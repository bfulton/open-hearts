/// What the game on the web tells New Relic (net/report_error.dart): a
/// live game's line, by the first eight of its table's id, so that the
/// operator can lay it beside the relay's and the house's logs
/// (docs/how-to/look-into-a-lost-game.md), and no more of the id than
/// that: the whole of it is the table's address.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/build_info.dart' show buildTag;
import 'package:open_hearts/net/report_error.dart';

void main() {
  test('a line is told with its table by the first eight of its id, what the device saw, and the build', () {
    final told = <(String, Map<String, String>)>[];
    noticed = (message, attributes) => told.add((message, attributes));
    addTearDown(() => noticed = null);
    reportLine('game lost: the house let a turn run out',
        table: '83167bb6681da6f1b6f4ab8931028fbb', seen: 'the house let a turn run out at h0/t49; line up', line: '1 of 1 open');
    expect(told, hasLength(1));
    final (message, attributes) = told.single;
    expect(message, 'live: game lost: the house let a turn run out');
    expect(attributes, {
      'where': 'live table',
      'table': '83167bb6',
      'seen': 'the house let a turn run out at h0/t49; line up',
      'line': '1 of 1 open',
      'build': buildTag,
    });
  });
}
