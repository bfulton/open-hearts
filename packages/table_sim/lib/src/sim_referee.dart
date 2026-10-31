/// The table's referee on the simulator's clock, and the lines to it: what
/// the relay's table object does (`service/do/referee.mjs`), done the same
/// way, so that a table run here is a table run there.
///
/// The referee takes the first start that names the table and is said by
/// one of its people, naming the referee's house if it names one — and
/// one, if the table is sealed; after it, events from the spec's people
/// and its house alone, each once. It stamps every entry with its clock,
/// notes a writer's last connection closing and its first opening again,
/// and adds a tick when asked, no oftener than `tickGapMs`. A line
/// delivers every entry after its own latency, in order, and when it
/// drops and comes back it asks again from the first it has not had
/// ([SimLine]). Every event goes into the log as that referee hands it
/// back, through JSON and a JavaScript object ([asJavaScriptHoldsIt]),
/// and reads there as it would read on the wire.
library;

import 'dart:convert';

import 'package:table/table.dart';

import 'virtual_clock.dart';

class SimReferee {
  SimReferee(this.clock, {this.table, this.house, this.tickGapMs = 250});

  final VirtualClock clock;

  /// The table this referee is for; any, until a start names one.
  String? table;

  /// The house of the relay this referee stands for.
  final PublicKey? house;
  final int tickGapMs;

  final List<LogEntry> log = [];
  TableSpec? spec;
  final Set<String> _ids = {};
  final Map<PublicKey, int> _open = {};
  final Set<PublicKey> _downLogged = {};
  final Set<SimLine> _listening = {};
  int _lastEntryAt = -1 << 40;

  /// Told of every entry as it is added.
  void Function(LogEntry entry)? onEntry;

  /// Told when a table starts here: where the house is called.
  void Function(TableSpec spec)? onStart;

  /// Told of every event any line is given to send, as it is given it:
  /// where the explorer changes one (tool/explore.dart).
  void Function(SimLine line, TableEvent event)? onSend;

  /// A line to this referee for [key].
  SimLine line(PublicKey key, {int latencyMs = 30, int reconnectMs = 1000}) =>
      SimLine._(this, key, latencyMs: latencyMs, reconnectMs: reconnectMs);

  Set<PublicKey> get _writers => {
        for (final h in spec!.seats)
          if (h is HumanSeat) h.key,
        if (spec!.house != null) spec!.house!,
      };

  void _append({TableEvent? event, Map<String, Object?>? unread, PublicKey? up, PublicKey? down}) {
    // The event as the relay's referee hands it on: what reads of it
    // there, and if nothing does, its bytes as they came, unread.
    if (event != null) {
      final wire = asJavaScriptHoldsIt(jsonDecode(jsonEncode(event.toJson()))) as Map<String, Object?>;
      event = TableEvent.parse(wire, verifySignature: false);
      if (event == null) unread = wire;
    }
    final e = LogEntry(n: log.length, t: clock.nowMs, event: event, unread: unread, up: up, down: down);
    log.add(e);
    _lastEntryAt = e.t;
    onEntry?.call(e);
    for (final l in List.of(_listening)) {
      l._deliver(e);
    }
  }

  void _receive(TableEvent e) {
    if (table != null && e.table != table) return;
    if (log.isEmpty) {
      if (e.kind != EventKind.start) return;
      final s = TableSpec.parse(e.body['spec']);
      if (s == null || s.id != e.table || s.seatOf(e.author) == null) return;
      if ((s.house != null && s.house != house) || (s.sealed && s.house == null)) return;
      table = s.id;
      spec = s;
      _ids.add(e.id);
      _append(event: e);
      onStart?.call(s);
      return;
    }
    if (e.kind == EventKind.start || !_writers.contains(e.author) || !_ids.add(e.id)) return;
    _append(event: e);
  }

  /// An event as [author] signed it, that does not read: logged as the
  /// relay's referee logs any event whose signature on its id checks,
  /// from a key it takes from.
  void receiveUnread(Map<String, Object?> raw, PublicKey author) {
    if (log.isEmpty || !_writers.contains(author) || raw['id'] is! String || !_ids.add(raw['id'] as String)) return;
    _append(unread: raw);
  }

  void _tick() {
    if (log.isEmpty || clock.nowMs - _lastEntryAt < tickGapMs) return;
    _append();
  }

  void _opened(SimLine l) {
    _open[l.key] = (_open[l.key] ?? 0) + 1;
    if (_open[l.key] == 1 && _downLogged.remove(l.key)) _append(up: l.key);
    _listening.add(l);
  }

  void _closed(SimLine l) {
    if (!_listening.remove(l)) return;
    final left = (_open[l.key] ?? 1) - 1;
    _open[l.key] = left;
    // Only a writer's comings and goings are the table's business.
    if (left == 0 && spec != null && _writers.contains(l.key) && _downLogged.add(l.key)) _append(down: l.key);
  }
}

/// [json] as a JavaScript object holds it, at every depth: the keys that
/// read as an array index ("0", "2", "10") ahead of the rest and in
/// numeric order, whatever order they came in, and the rest as they
/// came. The relay's referee is JavaScript, and an event it takes goes
/// back out written from the object it parsed (service/do/referee.mjs).
Object? asJavaScriptHoldsIt(Object? json) {
  if (json is List) return [for (final e in json) asJavaScriptHoldsIt(e)];
  if (json is! Map) return json;
  final keys = [for (final k in json.keys) k as String];
  final index = [for (final k in keys) if (_isIndex(k)) k]..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  return {for (final k in [...index, for (final k in keys) if (!_isIndex(k)) k]) k: asJavaScriptHoldsIt(json[k])};
}

bool _isIndex(String key) => RegExp(r'^(0|[1-9][0-9]{0,8})$').hasMatch(key);

/// One side's line to a [SimReferee].
class SimLine implements RefereeLine {
  SimLine._(this.referee, this.key, {required this.latencyMs, required this.reconnectMs});

  final SimReferee referee;
  final PublicKey key;

  /// How long a message takes each way.
  int latencyMs;

  /// How long a dropped line takes to come back.
  int reconnectMs;

  VirtualClock get _clock => referee.clock;

  void Function(LogEntry entry)? _onEntry;
  int _next = 0;
  bool _connected = false;
  bool _caughtUp = false;
  bool _closed = false;

  /// While set, the line is down and does not come back by itself.
  bool held = false;

  /// Each connection's number: what a message in flight on an old one is
  /// told apart by.
  int _epoch = 0;
  void Function(bool up)? _onUp;
  final Map<String, TableEvent> _pending = {};

  @override
  void open(int from, void Function(LogEntry entry) onEntry) {
    _next = from;
    _onEntry = onEntry;
    _connect();
  }

  void _connect() {
    if (_closed || held) return;
    final epoch = ++_epoch;
    _clock.schedule(latencyMs, () {
      if (_closed || held || epoch != _epoch) return;
      _connected = true;
      _caughtUp = false;
      referee._opened(this);
      for (final e in referee.log.skip(_next).toList()) {
        _deliver(e);
      }
      _clock.schedule(latencyMs, () {
        if (epoch != _epoch || !_connected) return;
        _caughtUp = true;
        _onUp?.call(up);
      });
      for (final e in _pending.values.toList()) {
        _sendNow(e, epoch);
      }
    });
  }

  void _deliver(LogEntry e) {
    final epoch = _epoch;
    _clock.schedule(latencyMs, () {
      if (_closed || !_connected || epoch != _epoch) return;
      if (e.n < _next) return;
      if (e.n > _next) {
        // A gap: asked again from where this side is.
        for (final missed in referee.log.sublist(_next, e.n)) {
          _deliver(missed);
        }
        _deliver(e);
        return;
      }
      _next++;
      final id = e.event?.id;
      if (id != null) _pending.remove(id);
      _onEntry?.call(e);
    });
  }

  @override
  void send(TableEvent event) {
    if (_closed) return;
    _pending[event.id] = event;
    if (_connected) _sendNow(event, _epoch);
    referee.onSend?.call(this, event);
  }

  /// [event] said again on this line, as a device that is not sure it
  /// got through says it: the referee takes each event once.
  void sendAgain(TableEvent event) {
    if (_connected && !_closed) _sendNow(event, _epoch);
  }

  void _sendNow(TableEvent e, int epoch) {
    _clock.schedule(latencyMs, () {
      if (_closed || epoch != _epoch || !_connected) return;
      referee._receive(e);
    });
  }

  @override
  void tick() {
    if (!_connected) return;
    final epoch = _epoch;
    _clock.schedule(latencyMs, () {
      if (epoch == _epoch && _connected) referee._tick();
    });
  }

  /// The socket drops; the line comes back after [reconnectMs], or not
  /// at all while [held].
  void drop() {
    if (!_connected && !held) return;
    _down();
    _clock.schedule(reconnectMs, _connect);
  }

  /// The line down until [release]: a phone off the network.
  void hold() {
    held = true;
    _down();
  }

  void release() {
    if (!held) return;
    held = false;
    _connect();
  }

  void _down() {
    _epoch++;
    if (_connected) referee._closed(this);
    _connected = false;
    _caughtUp = false;
    _onUp?.call(false);
  }

  @override
  bool get up => _connected && _caughtUp && !_closed;

  @override
  set onUp(void Function(bool up)? f) => _onUp = f;

  @override
  String? get refused => null;

  @override
  void close() {
    if (_closed) return;
    _down();
    _closed = true;
  }

  /// What this side has sent that the log has not yet handed back.
  List<TableEvent> get inFlight => List.of(_pending.values);

  /// Closed, as [close], with what was in flight still reaching the
  /// referee [landAfterMs] from now: a socket gone just after a send,
  /// whose last words got there anyway.
  void closeLeaving({required int landAfterMs}) {
    final last = inFlight;
    close();
    _clock.schedule(landAfterMs, () {
      for (final e in last) {
        referee._receive(e);
      }
    });
  }
}
