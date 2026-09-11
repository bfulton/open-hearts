/// The way into a live table: a name, a room code to host or join, and
/// the people arriving.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:table/table.dart';

import '../identity.dart';
import '../live_controller.dart';
import '../net/mesh_transport.dart';
import '../net/room.dart';
import '../net/standing.dart';
import '../theme.dart';
import 'live_page.dart';

/// Where the relay is: the local one while the app is served from a
/// dev machine, a public one otherwise. Editable on the page.
String defaultRelayUrl() {
  final host = Uri.base.host;
  if (host == 'localhost' || host == '127.0.0.1' || host.isEmpty) return 'ws://localhost:7447';
  return 'wss://relay.damus.io';
}

class LobbyPage extends StatefulWidget {
  const LobbyPage({super.key});

  @override
  State<LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<LobbyPage> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  late final TextEditingController _relay = TextEditingController(text: defaultRelayUrl());
  String? _error;
  bool _busy = false;
  Room? _room;
  WaitingRoom? _queue;
  RelayTransport? _transport;
  Signer? _signer;
  Standing? _standing;
  Timer? _waitClock;

  @override
  void initState() {
    super.initState();
    Identity.name().then((n) {
      if (n != null && mounted) _name.text = n;
    });
  }

  /// Ratings, from the relay that just answered — never from an
  /// address nobody has confirmed.
  Future<void> _loadStanding(Uri relay, Signer signer) async {
    try {
      final standing = await Standing.load(relay, signer);
      if (mounted) setState(() => _standing = standing);
    } catch (_) {
      // The rating shows next time.
    }
  }

  @override
  void dispose() {
    _room?.removeListener(_onRoom);
    _room?.dispose();
    _queueSub?.cancel();
    _queue?.close();
    _waitClock?.cancel();
    _transport?.close(); // a matched or started table has its own
    _name.dispose();
    _code.dispose();
    _relay.dispose();
    super.dispose();
  }

  /// Connects to the relay on [tag], or explains why not.
  Future<RelayTransport?> _connect(String tag) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name, so the others know who they are playing');
      return null;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Identity.setName(name);
      final signer = _signer ??= await Identity.signer();
      final url = Uri.parse(_relay.text.trim());
      final transport = RelayTransport(url: url, signer: signer, table: tag);
      await transport.ready.timeout(const Duration(seconds: 8));
      if (_standing == null) await _loadStanding(url, signer);
      setState(() {
        _transport = transport;
        _busy = false;
      });
      return transport;
    } on TimeoutException {
      setState(() {
        _busy = false;
        _error = 'No relay at ${_relay.text.trim()}';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not connect: $e';
      });
    }
    return null;
  }

  StreamSubscription<TableSpec>? _queueSub;

  /// Rated or unrated: into the pool, and wait to be seated — by
  /// whoever among the waiting has the lowest key, this device
  /// included.
  Future<void> _play(String pool) async {
    final transport = await _connect(poolTag(pool));
    if (transport == null) return;
    final ledger = _standing?.ledger ?? Ledger();
    final queue = WaitingRoom(
      relay: transport,
      pool: pool,
      name: _name.text.trim(),
      rating: (_standing?.mine ?? Rating.fresh).shown,
      botRating: Standing.botPicker(ledger),
    );
    _queueSub = queue.seated.listen((spec) {
      if (!mounted) return;
      _toTable(spec, queue.seatNames);
    });
    _waitClock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => _queue = queue);
  }

  /// The seated table has its own tag on the relay: a fresh transport
  /// there, WebRTC over it, and the live page.
  void _toTable(TableSpec spec, Map<int, String> seatNames) {
    final signer = _signer!;
    final relay = RelayTransport(url: Uri.parse(_relay.text.trim()), signer: signer, table: spec.id);
    final peers = [for (final h in spec.seats) if (h is HumanSeat) h.key];
    final relayUrl = Uri.parse(_relay.text.trim());
    final ledger = _standing?.ledger ?? Ledger();
    final controller = LiveController(
      spec: spec,
      seatNames: seatNames,
      signer: signer,
      transport: MeshTransport(relay: relay, peers: peers),
      ratingOf: spec.rated ? (id) => ledger.of(id) : null,
      onResult: (result) => Standing.publish(relayUrl, signer, result),
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => LivePage(controller: controller)));
  }

  Future<void> _enter({required bool host}) async {
    final code = host ? Room.newCode() : _code.text.trim().toUpperCase();
    if (!host && code.length != 4) return setState(() => _error = 'A room code is four letters');
    final transport = await _connect(code);
    if (transport == null) return;
    try {
      final name = _name.text.trim();
      final room = host
          ? Room.host(relay: transport, code: code, name: name)
          : Room.join(relay: transport, code: code, name: name);
      room.addListener(_onRoom);
      setState(() => _room = room);
    } on TimeoutException {
      setState(() {
        _busy = false;
        _error = 'No relay at ${_relay.text.trim()}';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not connect: $e';
      });
    }
  }

  void _onRoom() {
    final room = _room;
    if (room == null || !mounted) return;
    final spec = room.spec;
    if (spec != null) {
      room.removeListener(_onRoom);
      if (!room.seated) {
        setState(() => _error = 'That table filled up without you');
        return;
      }
      _toTable(spec, room.seatNames);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final queue = _queue;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: queue != null
                    ? _WaitingView(queue: queue, onCancel: () => Navigator.of(context).pop())
                    : room == null
                        ? _entry()
                        : _RoomView(room: room, onLeave: () => Navigator.of(context).pop()),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Play live',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Palette.gold)),
        const SizedBox(height: 6),
        Text(
          _standing == null
              ? 'Four seats, filled with whoever is waiting. Rated games count.'
              : 'You are rated ${_standing!.mine.shown}${_standing!.mine.provisional ? ', provisionally' : ''}, '
                  'from ${_standing!.ledger.gamesOf(_standing!.me)} rated game${_standing!.ledger.gamesOf(_standing!.me) == 1 ? '' : 's'}.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Palette.chromeDim),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: _field('Your name'),
          style: const TextStyle(color: Palette.chrome),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _play('rated'),
                style: _primary(),
                child: const Text('Rated', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _play('unrated'),
                style: _primary(),
                child: const Text('Unrated', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text('With friends',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.chromeDim, letterSpacing: 0.4)),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _busy ? null : () => _enter(host: true),
          style: _secondary(),
          child: const Text('Host a table', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                maxLength: 4,
                decoration: _field('Room code').copyWith(counterText: ''),
                style: const TextStyle(color: Palette.chrome, letterSpacing: 4, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: _busy ? null : () => _enter(host: false),
              style: _secondary(),
              child: const Text('Join', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 26),
        TextField(
          controller: _relay,
          decoration: _field('Relay'),
          style: const TextStyle(color: Palette.chromeDim, fontSize: 12),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
        ],
        const SizedBox(height: 18),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to the table', style: TextStyle(color: Palette.chromeDim)),
        ),
      ],
    );
  }

  static InputDecoration _field(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Palette.chromeDim),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Palette.gold),
        ),
      );

  static ButtonStyle _primary() => FilledButton.styleFrom(
        backgroundColor: Palette.gold,
        foregroundColor: Felt.dark,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );

  static ButtonStyle _secondary() => OutlinedButton.styleFrom(
        foregroundColor: Palette.chrome,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
}

/// Waiting to be seated. Nothing to do but wait, and it is not long:
/// a round every five seconds, and bots after ten.
class _WaitingView extends StatelessWidget {
  const _WaitingView({required this.queue, required this.onCancel});

  final WaitingRoom queue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final waited = (DateTime.now().millisecondsSinceEpoch - queue.since) ~/ 1000;
    final others = queue.present.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${queue.pool == 'rated' ? 'Rated' : 'Unrated'} game',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Palette.chromeDim, letterSpacing: 0.4)),
        const SizedBox(height: 26),
        const Center(child: SizedBox(width: 30, height: 30, child: CircularProgressIndicator(color: Palette.gold, strokeWidth: 2.5))),
        const SizedBox(height: 22),
        const Text('Finding players',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Palette.gold)),
        const SizedBox(height: 6),
        Text('$waited s${others > 0 ? ', $others other${others == 1 ? '' : 's'} waiting' : ''} — bots fill any seat still empty at ten',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
        const SizedBox(height: 26),
        TextButton(onPressed: onCancel, child: const Text('Cancel', style: TextStyle(color: Palette.chromeDim))),
      ],
    );
  }
}

/// The room while it fills: the code, who is here, and the countdown.
class _RoomView extends StatelessWidget {
  const _RoomView({required this.room, required this.onLeave});

  final Room room;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final seconds = room.secondsToStart;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(room.isHost ? 'Your table' : 'Table ${room.code}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Palette.chromeDim, letterSpacing: 0.4)),
        const SizedBox(height: 6),
        Text(room.code,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: Palette.gold, letterSpacing: 10)),
        const SizedBox(height: 4),
        Text(
          !room.found
              ? 'Looking for that table…'
              : seconds == null
                  ? (room.isHost ? 'Read the code out. The table starts ten seconds after someone joins.' : 'Waiting for the host')
                  : 'Starting in $seconds s — empty seats go to bots',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Palette.chromeDim),
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(i < room.members.length ? Icons.person : Icons.smart_toy_outlined,
                    size: 16, color: i < room.members.length ? Palette.gold : Palette.chromeDim),
                const SizedBox(width: 10),
                Text(
                  i < room.members.length
                      ? (room.members[i].key == room.me ? '${room.members[i].name} (you)' : room.members[i].name)
                      : 'a bot, unless someone joins',
                  style: TextStyle(
                    fontSize: 15,
                    color: i < room.members.length ? Palette.chrome : Palette.chromeDim,
                    fontWeight: i < room.members.length ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 22),
        if (room.isHost)
          FilledButton(
            onPressed: room.members.length >= 2 ? room.start : null,
            style: _LobbyPageState._primary(),
            child: const Text('Start now', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        TextButton(onPressed: onLeave, child: const Text('Leave', style: TextStyle(color: Palette.chromeDim))),
      ],
    );
  }
}
