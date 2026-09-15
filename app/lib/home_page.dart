/// The front door, and everything that happens before a game: who you
/// are, the game you are asking for, and the three ways in — bots,
/// live, or friends at a link.
///
/// One screen, because all of it is one decision: the game's options
/// are a line above the live buttons, where the choice they describe
/// is about to be made. Who you are — your name and your avatar — is
/// the icon in the top right, which is the whole of your profile
/// (live/profile_sheet.dart); a game that needs a name and finds none
/// asks for it there rather than holding a field open on the door for
/// the many times it is not wanted. A table found or filled replaces
/// the door with the waiting screen or the room, and leaving either
/// brings it back.
///
/// This is also where a device comes online: it says it is here and
/// serves as a juror from the front door, not only from a table
/// (docs/04-live-play.md).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:table/table.dart';

import 'about_page.dart';
import 'avatar.dart';
import 'crypto/deal.dart';
import 'game_options.dart';
import 'identity.dart';
import 'live/profile_sheet.dart';
import 'live/live_page.dart';
import 'live/options_sheet.dart';
import 'live_controller.dart';
import 'net/address.dart';
import 'net/duty.dart';
import 'net/mesh_transport.dart';
import 'net/relays.dart';
import 'net/room.dart';
import 'net/share.dart';
import 'net/standing.dart';
import 'net/turn.dart';
import 'pictures.dart';
import 'table_page.dart';
import 'theme.dart';
import 'ui/doorway.dart';
import 'ui/folding_heart.dart';
import 'ui/header.dart';
import 'ui/player_icon.dart';
import 'ui/update_pill.dart';

/// Whether live play is open on this device. It is meant to become
/// something bought one day, and this is the one place that will
/// answer that question when it does; until then everybody has it.
bool liveOpen = true;

/// What the relays say back — a refusal, a notice, a drop — goes to
/// the console, where a person debugging a table can read it. Which
/// relays is the build's business (net/relays.dart), not the page's.
void _relayLog(String line) => debugPrint('relay: $line');

/// With `?e2e` in the address the table's every transition and the
/// mesh's every channel change go to the console too.
final _debugging = Uri.base.queryParameters.containsKey('e2e');

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.openRoom, this.online = true});

  /// A room to open onto, from a shared link.
  final String? openRoom;

  /// False in widget tests: the device keeps off the relays, so no
  /// presence connection outlives the test. The app is always online.
  final bool online;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Who this device is to everyone else: read off the device at the
  /// start, changed in the profile behind the icon in the corner.
  String _name = '';
  Avatar _avatar = Avatar.none;

  /// The game this device is asking for, off the device and back onto
  /// it when it changes (game_options.dart).
  GameOptions _options = const GameOptions();

  /// What this device does with the others' pictures: the list of
  /// people whose pictures it does not show, and the check it runs on
  /// the rest (pictures.dart). Read once, carried to the table.
  Pictures? _pictures;
  final List<Uri> _relays = appRelays();
  String? _error;
  bool _busy = false;

  /// A relay is taking its time and the device is still waiting. Not an
  /// error — there is nothing to do about it but wait — so it is said
  /// quietly and it goes as soon as one answers.
  bool _slow = false;
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

  StreamSubscription<TableSpec>? _queueSub;

  /// The heart at the top, held by a key of its own: the door, the
  /// waiting screen and the room put it in different places, and it is
  /// the same heart in all three — a fold part way through carries
  /// across the change instead of starting over (ui/doorway.dart).
  final _heart = GlobalKey();

  @override
  void initState() {
    super.initState();
    _restore();
    Pictures.load().then((p) {
      if (mounted) _pictures = p;
    });
    // A device that cannot play live has no business in the count of
    // who is here, or in a jury.
    if (widget.online && liveOpen) _goOnline();
  }

  /// Who this device is and what game it asks for, off the device. In
  /// that order: a link opens a room as soon as the name is known, and
  /// the room is started with the options.
  Future<void> _restore() async {
    final options = await GameOptions.load();
    final avatar = await Identity.avatar();
    final name = await Identity.name();
    if (!mounted) return;
    setState(() {
      _options = options;
      _avatar = avatar;
      _name = name ?? '';
    });
    // Here by a link: straight into the room — unless live play is
    // locked, which a link does not open. A device with no name yet is
    // asked for one on the way in.
    if (liveOpen && widget.openRoom != null) await _enter();
  }

  /// Online from the front door, not only from a table: this device is
  /// a juror to draw on as soon as the app is open, and it sees who
  /// else is about.
  Future<void> _goOnline() async {
    final signer = await Identity.signer();
    if (!mounted) return;
    setState(() => _signer = signer);
    Duty.on(_relays, signer, log: _debugging, crypto: dealCrypto).presence.ready.then((_) {
      if (mounted) setState(() => _listeningSinceMs = DateTime.now().millisecondsSinceEpoch);
    });
    _onlineClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
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
    _closeLobby();
    _onlineClock?.cancel();
    _refusalSub?.cancel();
    super.dispose();
  }

  /// Everything a waiting room or a room needs while it is open, shut:
  /// the pool, the room, and the transport they share — a matched or
  /// started table opens its own.
  void _closeLobby() {
    _queueSub?.cancel();
    _queueSub = null;
    _queue?.close();
    _queue = null;
    _waitClock?.cancel();
    _dropRoom();
    _transport?.close();
    _transport = null;
  }

  /// Lets go of the room. Every way out of one — started, refused,
  /// left — is an answer to the room's own notification, and a
  /// [ChangeNotifier] may not be disposed inside one, so the disposal
  /// waits for the notification to finish.
  void _dropRoom() {
    final room = _room;
    if (room == null) return;
    room.removeListener(_onRoom);
    scheduleMicrotask(room.dispose);
    _room = null;
    // Out of the room, so out of the address: a refresh from here is
    // the front door, not a table that has started or emptied.
    showRoom(null);
  }

  void _go(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  /// Connects to the relays on [tag], or explains why not. Nothing
  /// goes near a relay without a name on it.
  Future<RelayTransport?> _connect(String tag) async {
    if (await _named() == null || !mounted) return null;
    final relays = _relays;
    setState(() {
      _busy = true;
      _slow = false;
      _error = null;
    });
    RelayTransport? transport;
    try {
      final signer = _signer ??= await Identity.signer();
      transport = RelayTransport(relays: relays, signer: signer, table: tag, log: _relayLog, pinned: pinnedRelays(relays));
      _refusalSub?.cancel();
      _refusalSub = transport.refusals.listen((r) {
        if (mounted) setState(() => _relayNote = r == null ? null : 'No relay will take this device\'s events: $r');
      });
      await waitForRelay(transport.ready, slow: () {
        if (mounted) setState(() => _slow = true);
      });
      if (!mounted) {
        transport.close();
        return null;
      }
      // A relay answered: from here on this device is online to
      // everyone, and a juror when drawn.
      Duty.on(relays, signer, log: _debugging, crypto: dealCrypto);
      _iceServers ??= const [];
      iceServersFor(signer).then((servers) => _iceServers = servers);
      if (_standing == null) await _loadStanding(relays, signer);
      setState(() {
        _transport = transport;
        _busy = false;
        _slow = false;
      });
      return transport;
    } on TimeoutException {
      _fell(transport, _noRelay);
    } catch (e) {
      _fell(transport, 'Could not connect: $e');
    }
    return null;
  }

  /// The connection did not come off: the sockets go, and the screen
  /// says why rather than sitting on a spinner.
  void _fell(RelayTransport? transport, String why) {
    _refusalSub?.cancel();
    _refusalSub = null;
    transport?.close();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _slow = false;
      _error = why;
    });
  }

  /// Nothing the player can change but the connection: the relays are
  /// the build's.
  static const _noRelay = 'No relay answered. Check the connection and try again.';



  /// Into the pool the options ask for, and wait to be seated — by
  /// whoever among the waiting has the lowest key, this device
  /// included. Everyone in a pool wants the same game, so the score it
  /// plays to is part of the pool's own name.
  Future<void> _play() async {
    final options = _options;
    final transport = await _connect(poolTag(options.pool, target: options.target));
    if (transport == null) return;
    final ledger = _standing?.ledger ?? Ledger();
    final queue = WaitingRoom(
      relay: transport,
      pool: options.pool,
      target: options.target,
      name: _name,
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
  /// there, WebRTC over it, and the live page over the front door — so
  /// leaving the table comes back here.
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
      onResult: (result) {
        // The fold that turns results into ratings is arithmetic this
        // device does itself, so the game's own sheet can say what it
        // did to your rating without waiting to hear the result back
        // off a relay — and the door behind the table has the new
        // rating on it when you get there.
        ledger.apply(result);
        unawaited(Standing.publish(relays, signer, result));
      },
      pictures: _pictures,
    );
    if (_debugging) controller.client.log = (l) => debugPrint('table: $l');
    setState(_closeLobby);
    _go(LivePage(controller: controller));
  }

  /// Into the room this device arrived at by a link, or a new one of
  /// its own: nobody types a code, so a room is either started here or
  /// opened from a link someone sent. Whoever is there is the table,
  /// and the first to arrive is nobody special.
  Future<void> _enter() async {
    final code = widget.openRoom ?? Room.newCode();
    final transport = await _connect(code);
    if (transport == null) return;
    try {
      final room = Room.enter(relay: transport, code: code, name: _name, avatar: _avatar, target: _options.target);
      room.addListener(_onRoom);
      setState(() => _room = room);
      // The room is its link, and the link is in the address bar while
      // this device is in it (net/address.dart).
      showRoom(code);
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

  /// Who you are here, in one sheet: the name the others see and the
  /// face they see it on. Both are kept on the device as soon as the
  /// sheet is done with.
  Future<void> _editProfile() async {
    final chosen = await showProfile(context, current: (name: _name, avatar: _avatar), seed: _signer?.publicKey ?? '');
    if (chosen == null || !mounted) return;
    setState(() {
      _name = chosen.name;
      _avatar = chosen.avatar;
    });
    await Identity.setName(chosen.name);
    await Identity.setAvatar(chosen.avatar);
  }

  /// The name the others will see, asked for if this device has none:
  /// nothing is played live without one, and the place to give it is
  /// the profile. Null when the sheet comes back without a name, which
  /// is the player saying not now.
  Future<String?> _named() async {
    if (_name.isNotEmpty) return _name;
    await _editProfile();
    return _name.isEmpty ? null : _name;
  }

  Future<void> _changeOptions() async {
    final chosen = await showGameOptions(context, current: _options);
    if (chosen == null || !mounted) return;
    setState(() => _options = chosen);
    await chosen.save();
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
      setState(() {
        _dropRoom();
        _error = room.refusal;
      });
      return;
    }
    if (spec != null) {
      if (!room.seated) {
        // A table under this code started without a seat for this
        // device: back to the front door, where the line can be read.
        setState(() {
          _dropRoom();
          _error = 'That table filled up without you';
        });
        return;
      }
      room.removeListener(_onRoom);
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
          child: Stack(
            children: [
              Column(
                children: [
                  _chrome(),
                  Expanded(
                    child: Doorway(
                      heart: FoldingHeart(key: _heart, size: 46, color: Palette.gold),
                      // The app's name is the door's own: a screen with
                      // one thing to say says that instead.
                      title: queue == null && room == null,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          queue != null
                              ? _WaitingView(queue: queue, onCancel: () => setState(_closeLobby))
                              : room == null
                                  ? _entry()
                                  : RoomView(
                                      room: room,
                                      ledger: _standing?.ledger,
                                      onLeave: () => setState(_closeLobby),
                                      onShare: () => _share(room.code),
                                    ),
                          if (_relayNote != null && (queue != null || room != null)) ...[
                            const SizedBox(height: 14),
                            Text(_relayNote!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const Positioned(right: 10, bottom: 8, child: UpdatePill()),
            ],
          ),
        ),
      ),
    );
  }

  /// The line above everything: the menu on the left, the same control
  /// the table's line carries (ui/header.dart), holding what is not the
  /// game; and on the right how you look to the others, which is the
  /// way into your profile.
  Widget _chrome() {
    return Row(
      children: [
        MenuButton(
          height: _chromeHeight,
          menu: [MenuAction('About', icon: Icons.info_outline, onSelected: () => _go(const AboutPage()))],
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: 'Your profile',
          onTap: _editProfile,
          child: InkWell(
            onTap: _editProfile,
            customBorder: const CircleBorder(),
            child: ExcludeSemantics(
              child: SizedBox(
                width: 48,
                height: _chromeHeight,
                child: Center(
                  child: PlayerIcon(name: _name.isEmpty ? '?' : _name, seed: _signer?.publicKey ?? '', avatar: _avatar, size: 32),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const _chromeHeight = 44.0;

  Widget _entry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Open source, no ads. Play alone or live.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: Palette.chromeDim)),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: () => _go(TablePage(target: _options.target)),
          style: _primary(),
          icon: const Icon(Icons.smart_toy_outlined, size: 20),
          label: const Text('Play bots', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 16),
        liveOpen ? _live() : const _LiveLocked(),
        if (_slow) ...[
          const SizedBox(height: 14),
          const Text('Still looking for a relay…',
              textAlign: TextAlign.center, style: TextStyle(color: Palette.chromeDim, fontSize: 13)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
        ],
      ],
    );
  }

  /// Live play: the game being asked for, and the two ways into one —
  /// whoever is waiting, or the people you send the link to.
  Widget _live() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_options.line,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Palette.chrome, letterSpacing: 0.2)),
              ),
              Semantics(
                button: true,
                label: 'Game options',
                onTap: _changeOptions,
                child: InkWell(
                  onTap: _changeOptions,
                  customBorder: const CircleBorder(),
                  child: const ExcludeSemantics(
                    child: SizedBox(
                      width: 38,
                      height: 38,
                      child: Icon(Icons.tune, size: 19, color: Palette.gold),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Text(
            _standing == null
                ? 'Four seats, filled with whoever is waiting.'
                : 'You are rated ${_standing!.mine.shown}${_standing!.mine.provisional ? ', provisionally' : ''}, '
                    'from ${_standing!.ledger.gamesOf(_standing!.me)} rated game${_standing!.ledger.gamesOf(_standing!.me) == 1 ? '' : 's'}.',
            style: const TextStyle(fontSize: 12, color: Palette.chromeDim),
          ),
          const SizedBox(height: 12),
          _PlayLive(online: _online, busy: _busy, onTap: _play),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy ? null : _enter,
            style: _secondary(),
            child: _Trying(busy: _busy, label: 'Play friends'),
          ),
          const SizedBox(height: 6),
          const Text(
            'A new table, and a link to send. A link from a friend opens theirs.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: Palette.chromeDim),
          ),
        ],
      ),
    );
  }

  static ButtonStyle _primary() => FilledButton.styleFrom(
        backgroundColor: Palette.gold,
        foregroundColor: Felt.dark,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );

  static ButtonStyle _secondary() => OutlinedButton.styleFrom(
        foregroundColor: Palette.chrome,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
}

/// When a slow relay is worth a word, and when there is nothing left
/// to wait for.
const sayItIsSlow = Duration(seconds: 8);
const stopWaiting = Duration(seconds: 40);

/// Waits for a relay to answer, and calls [slow] once if it is taking
/// its time.
///
/// How long a relay takes is not the device's to decide — a cold
/// network, a phone waking up, a crowd on one relay — so the first
/// deadline only changes what the screen says. The sockets go on
/// trying behind it and a relay that answers late still counts, which
/// is the whole point: a device that gave up at eight seconds would sit
/// on "no relay answered" with an open connection in its hand. The
/// second deadline is the end of it, and throws [TimeoutException].
Future<void> waitForRelay(
  Future<void> ready, {
  required void Function() slow,
  Duration sayIt = sayItIsSlow,
  Duration stopAt = stopWaiting,
}) {
  return ready.timeout(sayIt, onTimeout: () {
    slow();
    return ready.timeout(stopAt - sayIt);
  });
}

/// Into a live game, with how many devices are online on the button
/// itself: the count is the reason to press it now or to come back
/// later, so it belongs where the pressing happens.
class _PlayLive extends StatelessWidget {
  const _PlayLive({required this.online, required this.busy, required this.onTap});

  /// Devices online, this one included; null before the relays have
  /// been heard from.
  final int? online;

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = online;
    final count = n == null ? null : (n <= 1 ? 'Nobody else online' : '$n online');
    // One spoken line, so a screen reader and the suite read the same
    // thing the button says.
    final spoken = count == null ? 'Play live' : 'Play live, ${n! <= 1 ? 'nobody else online' : '$n online'}';
    return FilledButton(
      onPressed: busy ? null : onTap,
      style: _HomePageState._primary(),
      child: Semantics(
        label: spoken,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Trying(busy: busy, label: 'Play live', weight: FontWeight.w700, size: 15.5),
              // Holds its line while there is nothing to say, so the
              // button does not grow when the count arrives.
              SizedBox(
                height: 16,
                child: count == null
                    ? null
                    : Text(count,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Felt.dark.withValues(alpha: 0.75))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live play before it is opened: what is behind the lock, and that it
/// is not open yet. Nothing here asks for money — that is for the day
/// [liveOpen] answers something other than yes.
class _LiveLocked extends StatelessWidget {
  const _LiveLocked();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 20, color: Palette.chromeDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Live play', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chromeDim)),
                const SizedBox(height: 3),
                Text('Not open yet', style: TextStyle(fontSize: 12.5, color: Palette.chromeDim.withValues(alpha: 0.7))),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
        Text('${queue.target} points · ${queue.pool}',
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

/// The room while it fills: who is here, and the countdown. The code
/// is not on it — the link carries it, and a code on a screen is a code
/// to be read over a shoulder. The same screen for everyone in it; the
/// one who leads sees Start now, and that is the whole of the
/// difference.
class RoomView extends StatelessWidget {
  const RoomView({super.key, required this.room, required this.ledger, required this.onLeave, required this.onShare});

  final Room room;

  /// Ratings for the people here, from the results everyone signs;
  /// null until this device has read them off the relays.
  final Ledger? ledger;

  final VoidCallback onLeave;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final seconds = room.secondsToStart;
    final members = room.members;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                Expanded(
                  child: Text(
                    i < members.length
                        ? (members[i].key == room.me ? '${members[i].name} (you)' : members[i].name)
                        : 'a bot, unless someone joins',
                    style: TextStyle(
                      fontSize: 15,
                      color: i < members.length ? Palette.chrome : Palette.chromeDim,
                      fontWeight: i < members.length ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                // What they are rated, from the results everyone at
                // their tables signed. A rating nobody has played
                // enough games to settle carries its question mark.
                if (i < members.length && ledger != null) _Rated(rating: ledger!.of(members[i].key)),
              ],
            ),
          ),
        const SizedBox(height: 22),
        if (room.amLeader)
          FilledButton(
            onPressed: members.length >= 2 ? room.start : null,
            style: _HomePageState._primary(),
            child: const Text('Start now', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        TextButton(onPressed: onLeave, child: const Text('Leave', style: TextStyle(color: Palette.chromeDim))),
      ],
    );
  }
}

/// A button's label while the relays are being reached: the word it
/// had, and a turning ring beside it, because finding a relay takes a
/// moment and a button that only greys out reads as a button that did
/// nothing.
class _Trying extends StatelessWidget {
  const _Trying({required this.busy, required this.label, this.weight = FontWeight.w600, this.size = 14});

  final bool busy;
  final String label;
  final FontWeight weight;
  final double size;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, style: TextStyle(fontSize: size, fontWeight: weight));
    if (!busy) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(strokeWidth: 2, color: Palette.chromeDim.withValues(alpha: 0.9)),
        ),
        const SizedBox(width: 9),
        text,
      ],
    );
  }
}

/// A player's rating on a roster line: the number, and a question mark
/// while too few games have settled it.
class _Rated extends StatelessWidget {
  const _Rated({required this.rating});

  final Rating rating;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'rated ${rating.shown}${rating.provisional ? ', provisionally' : ''}',
      child: ExcludeSemantics(
        child: Text(
          '${rating.shown}${rating.provisional ? '?' : ''}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
            color: Palette.chromeDim,
          ),
        ),
      ),
    );
  }
}
