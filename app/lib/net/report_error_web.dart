import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Through `newrelic.noticeError`, where the page loaded the agent (on
/// production only: observability.js does nothing elsewhere). An Error
/// made here, so the agent groups by the message and shows the stack
/// as the app had it.
void notice(String message, String stack, Map<String, String> attributes) {
  final agent = globalContext['newrelic'];
  if (agent == null || !agent.isA<JSObject>()) return;
  try {
    final error = (globalContext['Error'] as JSFunction).callAsConstructor<JSObject>(message.toJS);
    if (stack.isNotEmpty) error['stack'] = '$message\n$stack'.toJS;
    (agent as JSObject).callMethod<JSAny?>('noticeError'.toJS, error, attributes.jsify());
  } catch (_) {
    // Telling of an error is never another one.
  }
}
