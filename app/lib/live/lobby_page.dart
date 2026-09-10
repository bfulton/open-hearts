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
  RelayTransport? _transport;
  Signer? _signer;

  @override
  void initState() {
    super.initState();
    Identity.name().then((n) {
      if (n != null && mounted) _name.text = n;
    });
  }

  @override
  void dispose() {
    _room?.removeListener(_onRoom);
    _room?.dispose();
    if (_room?.spec == null) _transport?.close(); // else the table owns it
    _name.dispose();
    _code.dispose();
    _relay.dispose();
    super.dispose();
  }

  Future<void> _enter({required bool host}) async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'A name, so the others know who they are playing');
    final code = host ? Room.newCode() : _code.text.trim().toUpperCase();
    if (!host && code.length != 4) return setState(() => _error = 'A room code is four letters');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Identity.setName(name);
      final signer = _signer ??= await Identity.signer();
      final url = Uri.parse(_relay.text.trim());
      final transport = RelayTransport(url: url, signer: signer, table: code);
      await transport.ready.timeout(const Duration(seconds: 8));
      final room = host
          ? Room.host(relay: transport, code: code, name: name)
          : Room.join(relay: transport, code: code, name: name);
      room.addListener(_onRoom);
      setState(() {
        _transport = transport;
        _room = room;
        _busy = false;
      });
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
      final peers = [for (final h in spec.seats) if (h is HumanSeat) h.key];
      final transport = MeshTransport(relay: _transport!, peers: peers);
      final controller = LiveController(
        spec: spec,
        seatNames: room.seatNames,
        signer: _signer!,
        transport: transport,
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => LivePage(controller: controller)),
      );
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: room == null ? _entry() : _RoomView(room: room, onLeave: () => Navigator.of(context).pop()),
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
        const Text('Four seats. Host a table and read out the code, or join one.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Palette.chromeDim)),
        const SizedBox(height: 22),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: _field('Your name'),
          style: const TextStyle(color: Palette.chrome),
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _busy ? null : () => _enter(host: true),
          style: _primary(),
          child: const Text('Host a table', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 22),
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
            FilledButton(
              onPressed: _busy ? null : () => _enter(host: false),
              style: _primary(),
              child: const Text('Join', style: TextStyle(fontWeight: FontWeight.w700)),
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
