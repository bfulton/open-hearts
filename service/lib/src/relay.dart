/// The relay under the Dart suites: the one the Cloudflare object runs.
///
/// `service/do/relay.mjs` is the relay, and `service/do/referee.mjs` the
/// table's referee in it; the Cloudflare object (`service/do/worker.mjs`)
/// and a plain node host (`service/do/host.mjs`) both drive them. This
/// is that host, started as a process, under the deployed object's own
/// rules: one object per tag, the tag in the address ([url] carries
/// [tagMark]), the ephemeral kinds and the tag's own lobby taken and
/// nothing else, a table's limits, and a table's tag its log. So every
/// suite here — a table played over real sockets, presence, the waiting
/// room, one device at a time — meets the relay the app meets.
///
///     cd service && dart test
///
/// What crosses the process line does so only for a test. The counts a
/// test reads — `stored`, `connections` — are getters with nothing to
/// await, so the host writes them to a small file before it answers
/// anything a test could notice them through, and they are read back
/// from there when asked for. A `refuse` policy is a Dart closure: the
/// host asks over the pipe and waits for the answer, so a test that
/// counts how often its policy was consulted is counting consultations
/// that really happened. And a table or a pool that wants its house and
/// does not have it is said on the host's stdout, where the deployed
/// object wakes the house's container: [onWanted].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:table/table.dart';

class Relay {
  Relay({this.log, String? Function(NostrEvent event)? refuse, this.gate, this.house, this.onWanted}) {
    _refuse = refuse;
  }

  /// The service's key, to ask every socket who it is by, as the
  /// deployed relay does (service/do/relay.mjs, serviceGate); null asks
  /// nobody.
  final String? gate;

  /// The house (service/do/referee.mjs): the key a sealed table's spec
  /// has to name, and the one the results are taken from; null for
  /// none, which referees no sealed table.
  final PublicKey? house;

  /// Told of a table each time it wants its house and the house is not
  /// on its log: as a sealed table starts, and while the house is away;
  /// and of a pool, while somebody waits there and the house is away.
  final void Function(String tag)? onWanted;

  /// Tells the relay that [account]'s device in use is now the one of
  /// [epoch], as the account's own object tells the deployed one, and
  /// [why] the devices before it are cut off: another device is in use,
  /// unless it says otherwise.
  void revoke(String account, int epoch, {String? why}) => _tell({
        'revoke': {'account': account, 'epoch': epoch, 'why': ?why},
      });

  /// Receives the host's own log lines, connections and subscriptions
  /// and refusals, or null to start it quiet.
  final void Function(String line)? log;

  String? Function(NostrEvent event)? _refuse;

  Process? _host;
  Directory? _scratch;
  File? _counts;
  int? _port;

  /// A policy, for a test: the reason to refuse an event that checks
  /// out, or null to take it — what a relay does when it rate-limits a
  /// client or turns a kind away. Asked of what the object itself
  /// takes; never of a table's events, which are its referee's.
  set refuse(String? Function(NostrEvent event)? policy) {
    _refuse = policy;
    // The host asks nothing while it is told there is nothing to ask.
    _tell({'refuse': policy != null});
  }

  /// The port the relay listens on once [serve] has returned.
  int get port => _port ?? (throw StateError('the relay is not serving'));

  /// The relay, with the tag left for each client to put in.
  Uri get url => Uri(scheme: 'ws', host: '127.0.0.1', port: port, pathSegments: const [tagMark]);

  /// How many clients are connected, and how many events are stored.
  int get connections => _count('connections');
  int get stored => _count('stored');

  int _count(String what) {
    try {
      return (jsonDecode(_counts!.readAsStringSync()) as Map)[what] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> serve({int port = 0}) async {
    final here = await Isolate.resolvePackageUri(Uri.parse('package:service/src/relay.dart'));
    if (here == null) throw StateError('cannot find the relay host beside this package');
    final script = File.fromUri(here.resolve('../../do/host.mjs')).path;
    _scratch = Directory.systemTemp.createTempSync('open-hearts-relay');
    _counts = File('${_scratch!.path}/counts.json')..writeAsStringSync('{}');
    final host = await Process.start('node', [
      script,
      '--port', '$port',
      '--stats', _counts!.path,
      '--control',
      '--object',
      if (gate != null) ...['--gate', gate!],
      if (house != null) ...['--house', house!],
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
  /// listening, and what it asks and says, which is JSON.
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
    if (question['wanted'] case final String table) return onWanted?.call(table);
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
