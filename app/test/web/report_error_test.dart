/// On a page (flutter test --platform chrome): an error goes to the
/// browser agent as an Error with the app's message and stack and the
/// build, a few to a page load, and nothing breaks where there is no
/// agent.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/report_error.dart';

void main() {
  test('told to newrelic.noticeError, at most a few times a page load', () {
    // No agent: nothing happens, and nothing throws.
    reportError(StateError('before the agent'), StackTrace.current);

    final seen = <(String, String, String)>[];
    final agent = JSObject();
    agent['noticeError'] = ((JSObject error, JSObject attributes) {
      seen.add((
        (error['message'] as JSString).toDart,
        (error['stack'] as JSString).toDart,
        (attributes['where'] as JSString).toDart,
      ));
    }).toJS;
    globalContext['newrelic'] = agent;

    reportError(StateError('a table went grey'), StackTrace.current, where: 'building TableView');
    expect(seen, hasLength(1));
    expect(seen.single.$1, 'Bad state: a table went grey');
    expect(seen.single.$2, startsWith('Bad state: a table went grey\n'));
    expect(seen.single.$3, 'building TableView');

    for (var i = 0; i < 50; i++) {
      reportError(StateError('every frame'), null);
    }
    // One before the agent, then the rest up to the limit.
    expect(seen.length, reportedAtMost - 1);
  });
}
