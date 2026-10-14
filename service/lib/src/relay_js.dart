/// The JS relay core under the Dart suites.
///
/// `service/do/relay.mjs` is the relay the Cloudflare object runs, and
/// the whole point of it is that a client meets the same NIP-01 subset
/// there as here. The way to know that is to run the tests written
/// against the Dart relay against the JS one instead, so
/// this is that relay wearing the same class: a node process hosting
/// the core (`service/do/host.mjs`), the same constructor the tests
/// call, the same `url` to connect to.
///
///     cd service && OH_RELAY=js dart test
///
/// Two things cross the process line, and only ever for a test. The
/// counts a test reads — `stored`, `connections` — are getters with
/// nothing to await, so the host writes them to a small file before it
/// answers anything a test could notice them through, and they are read
/// back from there when asked for. And a `refuse` policy is a Dart
/// closure: the host asks over the pipe and waits for the answer, so a
/// test that counts how often its policy was consulted is counting
/// consultations that really happened.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:table/table.dart';

import 'relay.dart';

class JsRelay implements Relay {
  JsRelay({this.keep = 10000, this.log, String? Function(NostrEvent event)? refuse, this.object = false, this.gate}) {
    _refuse = refuse;
  }

  /// The service's key, to ask every socket who it is by, as the
  /// deployed relay does (service/do/relay.mjs, serviceGate); null asks
  /// nobody.
  final String? gate;

  /// Tells the relay that [account]'s device in use is now the one of
  /// [epoch], as the account's own object tells the deployed one, and
  /// [why] the devices before it are cut off: another device is in use,
  /// unless it says otherwise.
  void revoke(String account, int epoch, {String? why}) => _tell({
        'revoke': {'account': account, 'epoch': epoch, 'why': ?why},
      });

  /// How many stored events the host holds before the oldest go.
  final int keep;

  /// The deployed object's rules (`OH_RELAY=object`): one object per
  /// tag, the tag in the address ([url] carries [tagMark]), the
  /// ephemeral kinds and the tag's own lobby taken and nothing else,
  /// and a table's limits.
  final bool object;

  /// Receives the host's own log lines, connections and subscriptions
  /// and refusals, or null to start it quiet.
  final void Function(String line)? log;

  String? Function(NostrEvent event)? _refuse;

  Process? _host;
  Directory? _scratch;
  File? _counts;
  int? _port;

  @override
  set refuse(String? Function(NostrEvent event)? policy) {
    _refuse = policy;
    // The host asks nothing while it is told there is nothing to ask.
    _tell({'refuse': policy != null});
  }

  @override
  int get port => _port ?? (throw StateError('the relay is not serving'));

  @override
  Uri get url => Uri(scheme: 'ws', host: '127.0.0.1', port: port, pathSegments: object ? const [tagMark] : null);

  @override
  int get connections => _count('connections');

  @override
  int get stored => _count('stored');

  int _count(String what) {
    try {
      return (jsonDecode(_counts!.readAsStringSync()) as Map)[what] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> serve({int port = 0}) async {
    final here = await Isolate.resolvePackageUri(Uri.parse('package:service/src/relay_js.dart'));
    if (here == null) throw StateError('cannot find the relay host beside this package');
    final script = File.fromUri(here.resolve('../../do/host.mjs')).path;
    _scratch = Directory.systemTemp.createTempSync('open-hearts-relay');
    _counts = File('${_scratch!.path}/counts.json')..writeAsStringSync('{}');
    final host = await Process.start('node', [
      script,
      '--port', '$port',
      '--keep', '$keep',
      '--stats', _counts!.path,
      '--control',
      if (object) '--object',
      if (gate != null) ...['--gate', gate!],
      if (log == null) '--quiet',
    ]);
    _host = host;
    final up = Completer<void>();
    host.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) => _line(line, up));
    host.stderr.transform(utf8.decoder).listen((e) => log?.call('relay host: $e'));
    unawaited(host.exitCode.then((code) {
      if (!up.isCompleted) up.completeError(StateError('the relay host exited $code'));
    }));
    if (_refuse != null) _tell({'refuse': true});
    await up.future.timeout(const Duration(seconds: 30));
  }

  /// The host's stdout: its own log, the line saying where it is
  /// listening, and the questions it asks, which are JSON.
  void _line(String line, Completer<void> up) {
    if (line.startsWith('{')) return _asked(line);
    final where = RegExp(r'^relay ws://\S+:(\d+)$').firstMatch(line);
    if (where == null) return log?.call(line);
    _port = int.parse(where.group(1)!);
    if (!up.isCompleted) up.complete();
  }

  void _asked(String line) {
    Map<String, Object?> question;
    try {
      question = jsonDecode(line) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final ask = question['ask'];
    if (ask is! int) return;
    // The host has already checked the signature; checking it again
    // here would cost a test seventeen milliseconds to learn nothing.
    final event = NostrEvent.parse(question['event'], verifySignature: false);
    _tell({'answer': ask, 'reason': event == null ? null : _refuse?.call(event)});
  }

  void _tell(Map<String, Object?> message) {
    try {
      _host?.stdin.writeln(jsonEncode(message));
    } catch (_) {
      // The host has gone; the test is on its way out with it.
    }
  }

  @override
  Future<void> close() async {
    final host = _host;
    _host = null;
    host?.kill();
    await host?.exitCode;
    _port = null;
    _scratch?.deleteSync(recursive: true);
    _scratch = null;
  }
}
