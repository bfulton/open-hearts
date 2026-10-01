/// The front door, and everything that happens before a game: who you
/// are, the game you are asking for, and the three ways in — bots,
/// live, or friends at a link.
///
/// One screen, because all of it is one decision: the game's options
/// are a line above the live buttons, where the choice they describe
/// is about to be made. Who you are — your name and your avatar — is
/// the icon in the top right, which is the whole of your profile
/// (profile_page.dart); a game that needs a name and finds none
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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:table/table.dart';

import 'about_page.dart';
import 'avatar.dart';
import 'build_info.dart' show buildDate, reloadPage;
import 'crypto/deal.dart';
import 'entitlement.dart';
import 'feedback_page.dart';
import 'game_options.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'profile_page.dart';
import 'record_store.dart';
import 'stats.dart';
import 'live/live_page.dart';
import 'live/options_sheet.dart';
import 'live_controller.dart';
import 'net/address.dart';
import 'net/buying.dart';
import 'net/duty.dart';
import 'net/household.dart';
import 'net/mesh_transport.dart';
import 'net/network.dart';
import 'net/remote_config.dart';
import 'net/relays.dart';
import 'net/room.dart';
import 'net/share.dart';
import 'net/standing.dart';
import 'pace_store.dart';
import 'net/turn.dart';
import 'pictures.dart';
import 'subscribe_page.dart';
import 'table_page.dart';
import 'theme.dart';
import 'ui/doorway.dart';
import 'ui/folding_heart.dart';
import 'ui/header.dart';
import 'ui/player_icon.dart';
import 'ui/update_pill.dart';

/// Whether live play is open on this device: whether it holds a
/// licence the service signed and the date on it has not passed
/// (entitlement.dart, docs/06-service.md). Solo play never asks.
bool get liveOpen => Entitlement.current.live;

/// Whether the operator has shut live play's doors for everyone, for
/// now: the remote config's kill switch (net/remote_config.dart).
bool get livePaused => !RemoteSettings.current.config.live;

/// What the relays say back — a refusal, a notice, a drop — goes to
/// the console, where a person debugging a table can read it. Which
/// relays is the build's business (net/relays.dart), not the page's.
void _relayLog(String line) => debugPrint('relay: $line');

/// With `?e2e` in the address the table's every transition and the
/// mesh's every channel change go to the console too.
final _debugging = Uri.base.queryParameters.containsKey('e2e');

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.openRoom, this.openClaim, this.justBought = false, this.online = true});

  /// A room to open onto, from a shared link.
  final String? openRoom;

  /// A code this device arrived carrying, from another device's screen
  /// (net/household.dart).
  final String? openClaim;

  /// Whether this load is the one coming back from a checkout.
  final bool justBought;

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

  /// How long this device takes over a card, as it has measured itself
  /// (pace_store.dart). Nothing until it has played enough to know.
  Pace _pace = Pace.fresh;

  /// Whether the table now open has already had its cards folded into
  /// the pace: a table says it is done more than once.
  bool _paced = false;

  /// The game this device is asking for, off the device and back onto
  /// it when it changes (game_options.dart).
  GameOptions _options = const GameOptions();

  /// What this device does with the others' pictures: the list of
  /// people whose pictures it does not show, and the check it runs on
  /// the rest (pictures.dart). Read once, carried to the table.
  Pictures? _pictures;
  final List<Uri> _relays = appRelays();
  String? _error;

  /// Which way in is being opened, while it is being opened. Both are
  /// a relay connection away and both take a moment, and a spinner on
  /// the button that was not pressed is the door looking confused.
  _Opening? _opening;
  bool get _busy => _opening != null;

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

  /// Why a wait or a room has gone quiet, when that is known: every
  /// relay refused this device, or the device says it has no network.
  /// Unsaid, a room reads as though the others had left it — they drop
  /// off the list once they have not been heard for a few seconds — and
  /// a wait as one with nobody else in it. Gone again once the network
  /// is back.
  String? get _cutOff => _relayNote ?? (deviceOffline() ? context.l10n.noRelayAnswered : null);

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
    // Live play can open under this screen — a subscription bought on
    // the way back from a checkout, a licence the service was slow to
    // answer for — and when it does the door opens with it.
    Entitlement.current.addListener(_licensed);
    RemoteSettings.current.addListener(_configured);
    // A device that cannot play live has no business in the count of
    // who is here, or in a jury — nor one whose live play the operator
    // has paused.
    if (widget.online && liveOpen && !livePaused) _goOnline();
    // Neither of these is the relays, which is what `online` is about:
    // they are one call to the service each, and a test stands its own
    // behind that (net/household.dart).
    if (widget.justBought) unawaited(_justBought());
    if (widget.openClaim != null) unawaited(_arriving());
  }

  /// Arrived by a code another device showed (docs/06-service.md): this
  /// device joins that subscription and is given a licence of its own.
  Future<void> _arriving() async {
    final code = widget.openClaim;
    if (code == null) return;
    // Checked against the service this app is standing behind, which
    // is the entitlement's to name and not a constant's: a test stands
    // its own there, and so does the browser suite's rig.
    final said = await claimCode(await Identity.signer(), code, service: Entitlement.current.service);
    if (!mounted) return;
    if (said.answer != null) {
      await Entitlement.current.adopt(said.answer!);
    } else {
      setState(() => _error = said.refusal!.say(context.l10n));
    }
    // The code is spent, so the address lets it go. Afterwards, not
    // before: a refresh while it was still in the air should try again,
    // and writing the address from initState is writing it before the
    // engine's own history is there to be written over.
    _forget('claim');
  }

  /// Takes [name] out of the address, once the screen has been drawn at
  /// least once.
  void _forget(String name) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => forgetInAddress(name));
  }

  /// Live play opened, or shut, under this screen.
  void _licensed() {
    if (!mounted) return;
    setState(() {});
    if (widget.online && liveOpen && !livePaused && Duty.current == null) _goOnline();
  }

  /// The operator said something new. A pause shuts the doors from here
  /// on and leaves whatever is already under way alone: a device that is
  /// online stays a juror to the tables that drew it until the app is
  /// next started, since a game it holds a bot's hand in would end
  /// without it. A pause lifted opens them again.
  void _configured() {
    if (!mounted) return;
    setState(() {});
    if (widget.online && liveOpen && !livePaused && Duty.current == null) _goOnline();
  }

  /// Back from a checkout. The licence is behind a webhook Stripe sends
  /// us, which is usually there before the browser is — but not always,
  /// so this asks a few times before giving up and leaving the page
  /// saying what it says to anyone else.
  Future<void> _justBought() async {
    final signer = await Identity.signer();
    for (var tries = 0; tries < 8 && mounted && !liveOpen; tries++) {
      await Entitlement.current.refresh(signer);
      if (liveOpen) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    _forget('bought');
  }

  /// Who this device is and what game it asks for, off the device. In
  /// that order: a link opens a room as soon as the name is known, and
  /// the room is started with the options.
  Future<void> _restore() async {
    final options = await GameOptions.load();
    final avatar = await Identity.avatar();
    final name = await Identity.name();
    final pace = await PaceStore.load();
    if (!mounted) return;
    setState(() {
      _options = options;
      _avatar = avatar;
      _name = name ?? '';
      _pace = pace;
    });
    // Here by a link: straight into the room — unless live play is
    // locked, which a link does not open. A device with no name yet is
    // asked for one on the way in.
    if (liveOpen && !livePaused && widget.openRoom != null) await _enter();
  }

  /// Online from the front door, not only from a table: this device is
  /// a juror to draw on as soon as the app is open, and it sees who
  /// else is about.
  Future<void> _goOnline() async {
    final signer = await Identity.signer();
    if (!mounted) return;
    setState(() => _signer = signer);
    Duty.on(_relays, signer, log: _debugging, crypto: dealCrypto, dealWorker: dealWorker).presence.ready.then((_) {
      if (mounted) setState(() => _listeningSinceMs = DateTime.now().millisecondsSinceEpoch);
    });
    _onlineClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// How many devices are online, this one included, once this device
  /// has listened long enough to have heard everyone; null before.
  /// This one is counted whether or not it says it is here: one that
  /// cannot deal says nothing of itself (net/duty.dart), and the
  /// others around it are still the others.
  ///
  /// And null while the device says it has no network: the beats it
  /// heard before are not who is here now, and it hears nobody new.
  int? get _online {
    final since = _listeningSinceMs;
    final duty = Duty.current;
    if (since == null || duty == null || deviceOffline()) return null;
    if (DateTime.now().millisecondsSinceEpoch - since < duty.presence.everyMs + 1500) return null;
    final others = duty.presence.online(withinMs: 15000).difference({duty.presence.signer.publicKey});
    return others.length + 1;
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
    Entitlement.current.removeListener(_licensed);
    RemoteSettings.current.removeListener(_configured);
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

  Future<void> _go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  /// Connects to the relays on [tag], or explains why not. Nothing
  /// goes near a relay without a name on it.
  Future<RelayTransport?> _connect(String tag, _Opening opening) async {
    // A device that says it has no network will not find a relay by
    // waiting forty seconds for one (net/network.dart): it is told now,
    // before a name is asked for or anything is opened.
    if (deviceOffline()) {
      setState(() => _error = context.l10n.noRelayAnswered);
      return null;
    }
    if (await _named() == null || !mounted) return null;
    final relays = _relays;
    setState(() {
      _opening = opening;
      _slow = false;
      _error = null;
    });
    RelayTransport? transport;
    try {
      final signer = _signer ??= await Identity.signer();
      transport = RelayTransport(relays: relays, signer: signer, table: tag, log: _relayLog, pinned: pinnedRelays(relays));
      _refusalSub?.cancel();
      _refusalSub = transport.refusals.listen((r) {
        if (mounted) setState(() => _relayNote = r == null ? null : context.l10n.noRelayTakesEvents(r));
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
      Duty.on(relays, signer, log: _debugging, crypto: dealCrypto, dealWorker: dealWorker);
      _iceServers ??= const [];
      iceServersFor(signer).then((servers) {
        _iceServers = servers;
        // The same credentials serve this device's juror duty, whose
        // channels are made when a table summons it (net/duty.dart).
        Duty.ice = servers;
      });
      if (_standing == null) await _loadStanding(relays, signer);
      setState(() {
        _transport = transport;
        _opening = null;
        _slow = false;
      });
      return transport;
    } on TimeoutException {
      // Nothing the player can change but the connection: the relays
      // are the build's.
      _fell(transport, (l10n) => l10n.noRelayAnswered);
    } catch (e) {
      _fell(transport, (l10n) => l10n.couldNotConnect('$e'));
    }
    return null;
  }

  /// The connection did not come off: the sockets go, and the screen
  /// says why rather than sitting on a spinner.
  void _fell(RelayTransport? transport, String Function(AppLocalizations l10n) why) {
    _refusalSub?.cancel();
    _refusalSub = null;
    transport?.close();
    if (!mounted) return;
    setState(() {
      _opening = null;
      _slow = false;
      _error = why(context.l10n);
    });
  }

  /// Every live table is sealed, and a device that cannot run the deal
  /// does not sit down (docs/03-fair-deal.md, "As built"). It says so
  /// here, at the door, rather than connecting to find out; true when
  /// it has.
  bool _withoutDeal() {
    if (dealReady) return false;
    setState(() => _error = Room.noDeal(context.l10n));
    return true;
  }

  /// Into the pool the options ask for, and wait to be seated — by
  /// whoever among the waiting has the lowest key, this device
  /// included. Everyone in a pool wants the same game, so the score it
  /// plays to is part of the pool's own name.
  Future<void> _play() async {
    if (livePaused || _withoutDeal()) return;
    final options = _options;
    final transport = await _connect(poolTag(options.pool, target: options.target), _Opening.live);
    if (transport == null) return;
    final ledger = _standing?.ledger ?? Ledger();
    final queue = WaitingRoom(
      relay: transport,
      pool: options.pool,
      target: options.target,
      name: _name,
      rating: (_standing?.mine ?? Rating.fresh).shown,
      // What this device has measured of its own play, so it is seated
      // with people who play at about its speed (pace_store.dart).
      pace: _pace.stated,
      botRating: Standing.botPicker(ledger),
      sealed: true,
      // The tables this device hosts keep its remote config's clocks.
      timing: RemoteSettings.current.config.table,
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
    _waitClock = Timer.periodic(const Duration(seconds: 1), (_) {
      // Bots take every seat still empty at ten seconds, so a device
      // the relays can hear is seated a round or two after that. One
      // still waiting at the far deadline is one nobody hears — it
      // went offline, or its relays did — and even the seating it
      // hosts itself has to come back to it off a relay: the spinner
      // would turn for ever. So back to the door, saying why.
      if (DateTime.now().millisecondsSinceEpoch - queue.since >= stopWaiting.inMilliseconds) {
        setState(() {
          _closeLobby();
          _error = context.l10n.noRelayAnswered;
        });
        return;
      }
      setState(() {});
    });
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
      presence: Duty.on(relays, signer, log: _debugging, crypto: dealCrypto, dealWorker: dealWorker).presence,
      crypto: dealCrypto,
      dealWorker: dealWorker,
      ratingOf: spec.rated ? (id) => ledger.of(id) : null,
      onResult: (result) {
        // The fold that turns results into ratings is arithmetic this
        // device does itself, so the game's own sheet can say what it
        // did to your rating without waiting to hear the result back
        // off a relay — and the door behind the table has the new
        // rating on it when you get there.
        ledger.apply(result);
        unawaited(Standing.publish(relays, signer, result).then((taken) {
          if (!taken) debugPrint('result: no relay took it, after every try');
        }));
      },
      pictures: _pictures,
    );
    if (_debugging) controller.client.log = (l) => debugPrint('table: $l');
    // What this device measured of its own play goes on the device and
    // nowhere else (pace_store.dart). Folded when the table is done
    // with, since a game left early is still cards this player took
    // their own time over.
    controller.addListener(() {
      if (!controller.client.done || _paced) return;
      _paced = true;
      unawaited(PaceStore.fold(controller.client.myCardMs).then((pace) {
        if (mounted) setState(() => _pace = pace);
      }));
    });
    _paced = false;
    setState(_closeLobby);
    // Online *and* at a table, which another table's draw prefers:
    // somebody mid-game has a reason to still be here in a minute
    // (docs/04-live-play.md, "The sizing"). Cleared on the way back
    // to the front door, however the table ended.
    Duty.seated = true;
    unawaited(_go(LivePage(controller: controller)).whenComplete(() => Duty.seated = false));
  }

  /// Into the room this device arrived at by a link, or a new one of
  /// its own: nobody types a code, so a room is either started here or
  /// opened from a link someone sent. Whoever is there is the table,
  /// and the first to arrive is nobody special.
  Future<void> _enter() async {
    if (livePaused || _withoutDeal()) return;
    final code = widget.openRoom ?? Room.newCode();
    final transport = await _connect(code, _Opening.friends);
    if (transport == null) return;
    try {
      final room = Room.enter(
        relay: transport,
        code: code,
        name: _name,
        avatar: _avatar,
        target: _options.target,
        timing: RemoteSettings.current.config.table,
        // Ten seconds, unless the address asks for longer and is
        // allowed to (net/address.dart).
        startAfter: roomWait(Uri.base, standard: Room.startAfter),
      );
      room.addListener(_onRoom);
      setState(() => _room = room);
      // The room is its link, and the link is in the address bar while
      // this device is in it (net/address.dart).
      showRoom(code);
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _opening = null;
        _error = context.l10n.noRelayAnswered;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = null;
        _error = context.l10n.couldNotConnect('$e');
      });
    }
  }

  /// Who you are here, and how you have done: the name the others see,
  /// the face they see it on, and what the games say. The first two are
  /// kept on the device as soon as the page is left.
  Future<void> _editProfile() async {
    final chosen = await showProfile(
      context,
      current: (name: _name, avatar: _avatar),
      seed: _signer?.publicKey ?? '',
      stats: _statsOnThisDevice(),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _name = chosen.name;
      _avatar = chosen.avatar;
    });
    await Identity.setName(chosen.name);
    await Identity.setAvatar(chosen.avatar);
  }

  /// What the profile page shows about the games. The games played
  /// alone are the device's own to count; the rating is the relays' to
  /// say, and the standing this door already loaded when it connected
  /// is the same answer, so it is handed over rather than asked for
  /// again. A door told to stay off the relays asks them nothing here
  /// either, and nor does a device that says it has no network: it
  /// would only say so eight seconds later (net/network.dart).
  Stream<PlayerStats> _statsOnThisDevice() async* {
    final signer = _signer ??= await Identity.signer();
    yield* playerStats(
      store: PrefsRecordStore(),
      signer: signer,
      standing: _standing,
      relays: widget.online && !deviceOffline() ? _relays : null,
    );
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
      ..showSnackBar(SnackBar(content: Text(context.l10n.linkCopied, textAlign: TextAlign.center), duration: const Duration(milliseconds: 1600), width: 200));
  }

  void _onRoom() {
    final room = _room;
    if (room == null || !mounted) return;
    final spec = room.spec;
    if (room.refusal != null) {
      setState(() {
        _dropRoom();
        _error = Room.said(room.refusal!, context.l10n);
      });
      return;
    }
    if (spec != null) {
      if (!room.seated) {
        // A table under this code started without a seat for this
        // device: back to the front door, where the line can be read.
        setState(() {
          _dropRoom();
          _error = context.l10n.tableFilledWithoutYou;
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
                  const OperatorNotes(),
                  Expanded(
                    child: Doorway(
                      heart: FoldingHeart(key: _heart, size: 46, color: Palette.mark),
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
                          if (_cutOff != null && (queue != null || room != null)) ...[
                            const SizedBox(height: 14),
                            Text(_cutOff!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
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
    final l10n = context.l10n;
    return Row(
      children: [
        MenuButton(
          height: _chromeHeight,
          menu: [
            // Once live play is open here, this is where the date on the
            // licence is. Shut, the door itself says what it costs and has
            // the way to it, and the menu saying it again was a second way
            // to the one page.
            if (liveOpen)
              MenuAction(l10n.livePlay, icon: Icons.card_membership_outlined, onSelected: () => showSubscribe(context)),
            MenuAction(l10n.tellUsWhatsBroken, icon: Icons.feedback_outlined, onSelected: () => showFeedback(context)),
            MenuAction(l10n.about, icon: Icons.info_outline, onSelected: () => _go(const AboutPage())),
          ],
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: l10n.yourProfile,
          onTap: _editProfile,
          // The ink is the tap a finger makes; the Semantics above is the
          // one a screen reader does, so the ink says nothing of its own —
          // it was a second, nameless button inside the first.
          child: ExcludeSemantics(
            child: InkWell(
              onTap: _editProfile,
              customBorder: const CircleBorder(),
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
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.tagline, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: Palette.chromeDim)),
        const SizedBox(height: 22),
        FilledButton(
          onPressed: () => _go(TablePage(target: _options.target)),
          style: _primary(),
          child: Text(l10n.playSolo, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
        ),
        // Live play, as the operator has it now: paused for everyone, open
        // here, or offered — unless the paid tier is not being offered,
        // and then a device without it is not shown it.
        if (livePaused) ...[
          const SizedBox(height: 16),
          const _LivePaused(),
        ] else if (liveOpen) ...[
          const SizedBox(height: 16),
          _live(),
        ] else if (RemoteSettings.current.config.offer) ...[
          const SizedBox(height: 16),
          _LiveLocked(onTap: () => showSubscribe(context)),
        ],
        if (_slow) ...[
          const SizedBox(height: 14),
          Text(l10n.stillLookingForRelay, textAlign: TextAlign.center, style: const TextStyle(color: Palette.chromeDim, fontSize: 13)),
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
    final l10n = context.l10n;
    final standing = _standing;
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
                child: Text(l10n.gameLine(_options.target, _options.pool),
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Palette.chrome, letterSpacing: 0.2)),
              ),
              Semantics(
                button: true,
                label: l10n.gameOptions,
                onTap: _changeOptions,
                // As the profile's: the Semantics is the button, the ink
                // only the finger's.
                child: ExcludeSemantics(
                  child: InkWell(
                    onTap: _changeOptions,
                    customBorder: const CircleBorder(),
                    child: const SizedBox(
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
            standing == null
                ? l10n.fourSeatsWaiting
                : l10n.youAreRated(standing.mine.shown, flag(standing.mine.provisional), standing.ledger.gamesOf(standing.me)),
            style: const TextStyle(fontSize: 12, color: Palette.chromeDim),
          ),
          const SizedBox(height: 12),
          _PlayLive(online: _online, busy: _opening == _Opening.live, disabled: _busy, onTap: _play),
          const SizedBox(height: 10),
          // The same gold as the rest: two ways into a live game, and
          // neither is the lesser of them.
          FilledButton(
            onPressed: _busy ? null : _enter,
            style: _primary(),
            child: _Trying(busy: _opening == _Opening.friends, label: l10n.playFriends, weight: FontWeight.w700, size: 15.5),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.playFriendsDetail,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim),
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

  /// A way on that is not the door's own: gold, since it is something
  /// you can do, but drawn rather than filled, so that a screen has one
  /// thing it is for.
  static ButtonStyle _secondary() => OutlinedButton.styleFrom(
        foregroundColor: Palette.gold,
        side: const BorderSide(color: Palette.gold, width: 1.4),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );

}

/// The two ways into a live game, while one of them is being opened.
enum _Opening { live, friends }

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
  const _PlayLive({required this.online, required this.busy, required this.disabled, required this.onTap});

  /// Devices online, this one included; null before the relays have
  /// been heard from.
  final int? online;

  /// Whether this is the one being opened, which is what the spinner
  /// says; [disabled] is either of them being opened, which is what
  /// stops a second press.
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final n = online;
    final count = n == null ? null : l10n.onlineCount(n);
    // One spoken line, so a screen reader and the suite read the same
    // thing the button says.
    final spoken = n == null ? l10n.playLive : l10n.playLiveSpoken(n);
    return FilledButton(
      onPressed: disabled ? null : onTap,
      style: _HomePageState._primary(),
      child: Semantics(
        label: spoken,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Trying(busy: busy, label: l10n.playLive, weight: FontWeight.w700, size: 15.5),
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

/// Live play, not open here. The padlock is not the point: what live
/// play is and what it costs is, and the way to it — gold, like every
/// way on, but drawn rather than filled: Play solo is what the door is
/// for, and two filled buttons of one gold on one screen asked the eye
/// to choose before it had read either.
class _LiveLocked extends StatelessWidget {
  const _LiveLocked({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
                child: Text(l10n.livePlay,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chrome, letterSpacing: 0.2)),
              ),
              Text(l10n.pricePerYear(priceAmount),
                  style: const TextStyle(fontSize: 13, color: Palette.chrome, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.seatsOrFriends,
            style: const TextStyle(fontSize: 12, color: Palette.chromeDim),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onTap,
            style: _HomePageState._secondary(),
            child: Text(l10n.subscribe, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.aloneIsFree,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim),
          ),
        ],
      ),
    );
  }
}

/// Live play, paused by the operator for everyone (the remote config's
/// kill switch): said where the buttons were, with what is still open.
class _LivePaused extends StatelessWidget {
  const _LivePaused();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.livePlay,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chrome, letterSpacing: 0.2)),
          const SizedBox(height: 4),
          Text(l10n.livePaused, style: const TextStyle(fontSize: 12, color: Palette.chromeDim)),
        ],
      ),
    );
  }
}

/// What the operator has to say across the top of the front door
/// (net/remote_config.dart): a notice — an outage, a maintenance
/// window — and, to a build older than the one asked for, that it is.
/// Nothing at all when there is nothing to say.
class OperatorNotes extends StatelessWidget {
  const OperatorNotes({super.key, this.published = buildDate});

  /// The day this build was published: the build's own, unless a test
  /// says.
  final String published;

  // Listening for itself: it is a const widget in the door's tree, which
  // a rebuild of the door passes over as unchanged.
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: RemoteSettings.current, builder: (context, _) => _notes(context));

  Widget _notes(BuildContext context) {
    final l10n = context.l10n;
    final config = RemoteSettings.current.config;
    final notice = config.banner;
    final lines = <Widget>[
      if (notice != null) _line(notice.text.inLanguage(l10n.localeName), notice.warning ? Palette.danger : Palette.gold),
      if (config.updateDue(published))
        _line(config.updateText?.inLanguage(l10n.localeName) ?? (kIsWeb ? l10n.updateDueWeb : l10n.updateDueApp), Palette.gold,
            action: kIsWeb ? TextButton(onPressed: reloadPage, child: Text(l10n.reload)) : null),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(children: lines);
  }

  static Widget _line(String text, Color tone, {Widget? action}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tone.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, color: Palette.chrome))),
            ?action,
          ],
        ),
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
    final l10n = context.l10n;
    final waited = (DateTime.now().millisecondsSinceEpoch - queue.since) ~/ 1000;
    final others = queue.present.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.gameLine(queue.target, queue.pool),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Palette.chromeDim, letterSpacing: 0.4)),
        const SizedBox(height: 26),
        const Center(child: SizedBox(width: 30, height: 30, child: CircularProgressIndicator(color: Palette.gold, strokeWidth: 2.5))),
        const SizedBox(height: 22),
        Text(l10n.findingPlayers,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Palette.chrome)),
        const SizedBox(height: 6),
        Text(l10n.waitedLine(waited, others < 0 ? 0 : others),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
        const SizedBox(height: 26),
        TextButton(onPressed: onCancel, child: Text(l10n.cancel, style: const TextStyle(color: Palette.chromeDim))),
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
    final l10n = context.l10n;
    final seconds = room.secondsToStart;
    final members = room.members;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          seconds == null ? l10n.roomSendLink : l10n.roomStartingIn(seconds),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Palette.chromeDim),
        ),
        const SizedBox(height: 14),
        TextButton.icon(
          onPressed: onShare,
          icon: const Icon(Icons.ios_share, size: 17),
          label: Text(l10n.shareTheLink, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
                        ? (members[i].key == room.me ? l10n.nameIsYou(members[i].name) : members[i].name)
                        : l10n.emptySeat,
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
            child: Text(l10n.startNow, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        TextButton(onPressed: onLeave, child: Text(l10n.leave, style: const TextStyle(color: Palette.chromeDim))),
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
      label: context.l10n.ratedSpoken(rating.shown, flag(rating.provisional)),
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
