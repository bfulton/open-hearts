/// The way into a live table: a name, a room code to host or join, and
/// the people arriving.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:table/table.dart';

import '../crypto/deal.dart';
import '../identity.dart';
import '../live_controller.dart';
import '../net/duty.dart';
import '../net/relays.dart';
import '../net/mesh_transport.dart';
import '../net/room.dart';
import '../net/share.dart';
import '../net/standing.dart';
import '../net/turn.dart';
import '../avatar.dart';
import '../theme.dart';
import '../ui/player_icon.dart';
import 'avatar_picker.dart';
import 'live_page.dart';

/// What the relays say back — a refusal, a notice, a drop — goes to
/// the console, where a person debugging a table can read it. Which
/// relays is the build's business (net/relays.dart), not the page's.
void _relayLog(String line) => debugPrint('relay: $line');

/// With `?e2e` in the address the table's every transition and the
/// mesh's every channel change go to the console too.
final _debugging = Uri.base.queryParameters.containsKey('e2e');

/// opens the lobby with that room code in the field and hosts under it,
/// so a table of people testing a branch is one tap away. Unset in a
/// normal build.

class LobbyPage extends StatefulWidget {
  const LobbyPage({super.key, this.code});

  /// A room to go straight into: the code from a shared link.
  final String? code;

  @override
  State<LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<LobbyPage> {
  final _name = TextEditingController();

  /// How you look to the others: read off the device with the name,
  /// changed by tapping it.
  Avatar _avatar = Avatar.none;
  final List<Uri> _relays = appRelays();
  String? _error;
  bool _busy = false;
  Room? _room;
  WaitingRoom? _queue;
  RelayTransport? _transport;
  Signer? _signer;
  Standing? _standing;
  Timer? _waitClock;

  /// What the relays said when every one of them refused this device's
  /// latest event, while it waits or sits in a room; null while one
  /// takes them.
  String? _relayNote;
  StreamSubscription<String?>? _refusalSub;

  /// The ICE servers for this device's next table, fetched once the
  /// relays answer (turn.dart); none until then, and none at all on
  /// localhost.
  List<Map<String, Object?>>? _iceServers;

  /// Since when this device has been listening on the relays for who
  /// is online; null until they answer. The count is not shown for the
  /// first announcement period after, since the announcements are
  /// ephemeral and nobody is heard until they say so again.
  int? _listeningSinceMs;
  Timer? _onlineClock;

  @override
  void initState() {
    super.initState();
    Identity.avatar().then((a) {
      if (mounted) setState(() => _avatar = a);
    });
    Identity.name().then((n) {
      if (!mounted) return;
      if (n != null) _name.text = n;
      // Here by a link, with a name already: straight into the room.
      if (widget.code != null && n != null && n.isNotEmpty) _enter();
    });
    // Online from the lobby, not only from a table: this device is a
    // juror to draw on as soon as the app is open here, and it sees
    // who else is.
    Identity.signer().then((signer) {
      if (!mounted) return;
      _signer = signer;
      final duty = Duty.on(_relays, signer, log: _debugging, crypto: dealCrypto);
      duty.presence.ready.then((_) {
        if (mounted) setState(() => _listeningSinceMs = DateTime.now().millisecondsSinceEpoch);
      });
      _onlineClock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    });
  }

  /// How many devices are online, this one included, once this device
  /// has listened long enough to have heard everyone; null before.
  int? get _online {
    final since = _listeningSinceMs;
    final duty = Duty.current;
    if (since == null || duty == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - since < duty.presence.everyMs + 1500) return null;
    return duty.presence.online(withinMs: 15000).length;
  }

  /// Ratings, from the relays that just answered — never from an
  /// address nobody has confirmed.
  Future<void> _loadStanding(List<Uri> relays, Signer signer) async {
    try {
      final standing = await Standing.load(relays, signer);
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
    _onlineClock?.cancel();
    _refusalSub?.cancel();
    _transport?.close(); // a matched or started table has its own
    _name.dispose();
    super.dispose();
  }

  /// Connects to the relays on [tag], or explains why not.
  Future<RelayTransport?> _connect(String tag) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name, so the others know who they are playing');
      return null;
    }
    final relays = _relays;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Identity.setName(name);
      final signer = _signer ??= await Identity.signer();
      final transport = RelayTransport(relays: relays, signer: signer, table: tag, log: _relayLog, pinned: pinnedRelays(relays));
      _refusalSub?.cancel();
      _refusalSub = transport.refusals.listen((r) {
        if (mounted) setState(() => _relayNote = r == null ? null : 'No relay will take this device\'s events: $r');
      });
      await transport.ready.timeout(const Duration(seconds: 8));
      // A relay answered: from here on this device is online to
      // everyone, and a juror when drawn.
      Duty.on(relays, signer, log: _debugging, crypto: dealCrypto);
      _iceServers ??= const [];
      iceServersFor(signer).then((servers) => _iceServers = servers);
      if (_standing == null) await _loadStanding(relays, signer);
      setState(() {
        _transport = transport;
        _busy = false;
      });
      return transport;
    } on TimeoutException {
      setState(() {
        _busy = false;
        _error = _noRelay;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not connect: $e';
      });
    }
    return null;
  }

  /// Nothing the player can change but the connection: the relays are
  /// the build's.
  static const _noRelay = 'No relay answered. Check the connection and try again.';

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
      sealed: dealCrypto != null,
      avatar: _avatar.isDefault ? null : _avatar.toJson(withPicture: false),
      picture: _avatar.picture == null ? null : base64Encode(_avatar.picture!),
    );
    _queueSub = queue.seated.listen((spec) {
      if (!mounted) return;
      // The seating carried each seat's icon and colour; pictures came
      // on their own, by key.
      final avatars = <int, Avatar>{};
      for (var s = 0; s < spec.seats.length; s++) {
        final h = spec.seats[s];
        if (h is! HumanSeat) continue;
        if (h.key == _signer!.publicKey) {
          avatars[s] = _avatar;
          continue;
        }
        final chosen = Avatar.fromJson(queue.seatAvatars[s]);
        final picture = queue.pictures[h.key];
        avatars[s] = picture == null ? chosen : chosen.copyWith(picture: Avatar.fromJson({'picture': picture}).picture);
      }
      _toTable(spec, queue.seatNames, avatars);
    });
    _waitClock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => _queue = queue);
  }

  /// The seated table has its own tag on the relays: a fresh transport
  /// there, WebRTC over it, and the live page.
  void _toTable(TableSpec spec, Map<int, String> seatNames, Map<int, Avatar> seatAvatars) {
    final signer = _signer!;
    final relays = _relays;
    final relay = RelayTransport(relays: relays, signer: signer, table: spec.id, log: _relayLog, pinned: pinnedRelays(relays));
    final peers = [for (final h in spec.seats) if (h is HumanSeat) h.key];
    final ledger = _standing?.ledger ?? Ledger();
    final controller = LiveController(
      spec: spec,
      seatNames: seatNames,
      seatAvatars: seatAvatars,
      signer: signer,
      transport: MeshTransport(
        relay: relay,
        peers: peers,
        iceServers: _iceServers ?? const [],
        log: _debugging ? (l) => debugPrint('mesh: $l') : null,
      ),
      relay: relay,
      presence: Duty.on(relays, signer, log: _debugging, crypto: dealCrypto).presence,
      crypto: dealCrypto,
      ratingOf: spec.rated ? (id) => ledger.of(id) : null,
      onResult: (result) => Standing.publish(relays, signer, result),
    );
    if (_debugging) controller.client.log = (l) => debugPrint('table: $l');
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => LivePage(controller: controller)));
  }

  /// Into the room this device arrived at by a link, or a new one of
  /// its own: nobody types a code, so a room is either started here or
  /// opened from a link someone sent. Whoever is there is the table,
  /// and the first to arrive is nobody special.
  Future<void> _enter() async {
    final code = widget.code ?? Room.newCode();
    final transport = await _connect(code);
    if (transport == null) return;
    try {
      final name = _name.text.trim();
      final room = Room.enter(relay: transport, code: code, name: name, avatar: _avatar);
      room.addListener(_onRoom);
      setState(() => _room = room);
    } on TimeoutException {
      setState(() {
        _busy = false;
        _error = _noRelay;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not connect: $e';
      });
    }
  }

  Future<void> _pickAvatar() async {
    final chosen = await showAvatarPicker(context, current: _avatar, name: _name.text.isEmpty ? '?' : _name.text, seed: _signer?.publicKey ?? '');
    if (chosen == null || !mounted) return;
    setState(() => _avatar = chosen);
    await Identity.setAvatar(chosen);
  }

  /// The link to this room: the phone's share sheet where there is
  /// one, else onto the clipboard, and said so.
  Future<void> _share(String code) async {
    final link = roomLink(code);
    if (await shareLink(link)) return;
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Link copied', textAlign: TextAlign.center), duration: Duration(milliseconds: 1600), width: 200));
  }

  void _onRoom() {
    final room = _room;
    if (room == null || !mounted) return;
    final spec = room.spec;
    if (room.refusal != null) {
      room.removeListener(_onRoom);
      room.dispose();
      setState(() {
        _room = null;
        _error = room.refusal;
      });
      return;
    }
    if (spec != null) {
      room.removeListener(_onRoom);
      if (!room.seated) {
        setState(() => _error = 'That table filled up without you');
        return;
      }
      _toTable(spec, room.seatNames, room.seatAvatars);
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    queue != null
                        ? _WaitingView(queue: queue, onCancel: () => Navigator.of(context).pop())
                        : room == null
                            ? _entry()
                            : _RoomView(room: room, onLeave: () => Navigator.of(context).pop(), onShare: () => _share(room.code)),
                    if (_relayNote != null && (queue != null || room != null)) ...[
                      const SizedBox(height: 14),
                      Text(_relayNote!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
                    ],
                  ],
                ),
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
        const SizedBox(height: 10),
        _OnlineLine(count: _online),
        const SizedBox(height: 12),
        // How you will look at the table, big enough to see and plainly
        // a button: tapping it opens the icons, the colours and a
        // picture of your own (live/avatar_picker.dart).
        Row(
          children: [
            Semantics(
              button: true,
              label: 'Your avatar',
              onTap: _pickAvatar,
              child: InkWell(
                onTap: _pickAvatar,
                customBorder: const CircleBorder(),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    PlayerIcon(name: _name.text.isEmpty ? '?' : _name.text, seed: _signer?.publicKey ?? '', avatar: _avatar, size: 56),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Felt.mid,
                          shape: BoxShape.circle,
                          border: Border.all(color: Palette.gold.withValues(alpha: 0.7)),
                        ),
                        child: const Icon(Icons.edit_outlined, size: 12, color: Palette.gold),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: _field('Your name'),
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Palette.chrome),
              ),
            ),
          ],
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
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _busy ? null : _enter,
            style: _secondary().copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 15, horizontal: 12))),
            child: const Text('Play with friends', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'A new table, and a link to send. A link from a friend opens theirs.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: Palette.chromeDim),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
        ],
        const SizedBox(height: 18),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back', style: TextStyle(color: Palette.chromeDim)),
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
/// The same screen for everyone in it; the one who leads sees Start
/// now, and that is the whole of the difference.
class _RoomView extends StatelessWidget {
  const _RoomView({required this.room, required this.onLeave, required this.onShare});

  final Room room;
  final VoidCallback onLeave;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final seconds = room.secondsToStart;
    final members = room.members;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Table ${room.code}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Palette.chromeDim, letterSpacing: 0.4)),
        const SizedBox(height: 6),
        Text(room.code,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: Palette.gold, letterSpacing: 10)),
        const SizedBox(height: 4),
        Text(
          seconds == null
              ? 'Send the link. The table starts ten seconds after someone joins.'
              : 'Starting in $seconds s — empty seats go to bots',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Palette.chromeDim),
        ),
        const SizedBox(height: 14),
        TextButton.icon(
          onPressed: onShare,
          icon: const Icon(Icons.ios_share, size: 17),
          label: const Text('Share the link', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          style: TextButton.styleFrom(foregroundColor: Palette.gold),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                i < members.length
                    ? PlayerIcon(name: members[i].name, seed: members[i].key, avatar: members[i].avatar, size: 30)
                    : const SizedBox(width: 30, height: 30, child: Icon(Icons.smart_toy_outlined, size: 20, color: Palette.chromeDim)),
                const SizedBox(width: 10),
                Text(
                  i < members.length
                      ? (members[i].key == room.me ? '${members[i].name} (you)' : members[i].name)
                      : 'a bot, unless someone joins',
                  style: TextStyle(
                    fontSize: 15,
                    color: i < members.length ? Palette.chrome : Palette.chromeDim,
                    fontWeight: i < members.length ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 22),
        if (room.amLeader)
          FilledButton(
            onPressed: members.length >= 2 ? room.start : null,
            style: _LobbyPageState._primary(),
            child: const Text('Start now', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        TextButton(onPressed: onLeave, child: const Text('Leave', style: TextStyle(color: Palette.chromeDim))),
      ],
    );
  }
}

/// Who else has the app open, from the relays' presence: a count with
/// this device in it, or nothing while there is nothing to say yet.
/// One spoken line, "3 online", so a screen reader and the suite read
/// the same thing.
class _OnlineLine extends StatelessWidget {
  const _OnlineLine({required this.count});

  /// Devices online, this one included; null before the relays have
  /// been heard from.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final n = count;
    // Holds its line while there is nothing to say, so the page does
    // not jump when the count arrives.
    if (n == null) return const SizedBox(height: 18);
    final text = n <= 1 ? 'Nobody else online' : '$n online';
    return Semantics(
      label: text,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 18,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.people_outline, size: 14, color: n <= 1 ? Palette.chromeDim : Palette.gold.withValues(alpha: 0.85)),
              const SizedBox(width: 5),
              Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: n <= 1 ? Palette.chromeDim : Palette.gold.withValues(alpha: 0.9))),
            ],
          ),
        ),
      ),
    );
  }
}
