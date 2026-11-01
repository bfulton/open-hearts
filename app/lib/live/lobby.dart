/// The way from the front door to a live table (home_page.dart): the
/// relays this device connects to, the pool it waits in or the room it
/// sits in, and the table they open — and, from the moment a relay
/// answers, this device online to everyone (net/online.dart,
/// docs/explanation/live-play.md).
///
/// The home page supplies the lobby's identity, game options, name
/// prompt, strings and table-opening callback. `words` is read for each
/// message, so messages follow the home page's current locale.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

import '../avatar.dart';
import '../crypto/deal.dart';
import '../entitlement.dart';
import '../game_options.dart';
import '../identity.dart';
import '../l10n/l10n.dart';
import '../net/account_profile.dart';
import '../net/address.dart';
import '../net/game_records.dart';
import '../net/household.dart';
import '../net/in_use.dart';
import '../net/licence.dart' show houseKey;
import '../net/network.dart';
import '../net/online.dart';
import '../net/relays.dart';
import '../net/remote_config.dart';
import '../net/room.dart';
import '../net/seat_store.dart';
import '../net/standing.dart';
import '../pace_store.dart';
import '../pictures.dart';
import 'left_early.dart';
import 'live_controller.dart';

/// Whether live play is open on this device: whether it holds a
/// licence the service signed and the date on it has not passed
/// (entitlement.dart, docs/explanation/service.md) — and live play is
/// not shut here: it has not stepped back for another device of its
/// account, nor been told its account is suspended (net/in_use.dart).
/// Solo play never asks.
bool get liveOpen => Entitlement.current.live && !InUse.current.shut;

/// Whether the operator has shut live play's doors for everyone, for
/// now: the remote config's kill switch (net/remote_config.dart).
bool get livePaused => !RemoteSettings.current.config.live;

/// What the relays say back — a refusal, a notice, a drop — goes to
/// the console, where a person debugging a table can read it. Which
/// relays is the build's business (net/relays.dart), not the lobby's.
void _relayLog(String line) => debugPrint('relay: $line');

/// In a build being driven (net/address.dart) the table's every entry
/// and what presence does go to the console too.
final _debugging = driven(Uri.base);
final _onlineLog = _debugging ? (String l) => debugPrint('online: $l') : null;

/// The house this build seats live tables with (net/licence.dart), or
/// null in a build that names none, which seats nobody live.
PublicKey? get _house => RegExp(r'^[0-9a-f]{64}$').hasMatch(houseKey) ? houseKey : null;

/// How often a seated device notes that it is still at its table
/// (net/seat_store.dart, here): often enough that the note is never far
/// behind against SeatStore.comeBackWithin, rarely enough that a busy
/// table is not a write to the device's storage at every event.
const _seatSavedEvery = Duration(seconds: 10);

/// The two ways into a live game, while one of them is being opened.
enum Opening { live, friends }

/// When a slow relay is worth a word, and when there is nothing left
/// to wait for.
/// (Remote config, `waits`: the build's are eight seconds and forty.)
Duration get sayItIsSlow => waits.relaySlow;
Duration get stopWaiting => waits.relayGiveUp;

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
  Duration? sayIt,
  Duration? stopAt,
}) {
  sayIt ??= sayItIsSlow;
  stopAt ??= stopWaiting;
  final then = stopAt - sayIt;
  return ready.timeout(sayIt, onTimeout: () {
    slow();
    return ready.timeout(then);
  });
}

class Lobby extends ChangeNotifier {
  Lobby({
    required this.who,
    required this.options,
    required this.named,
    required this.words,
    required this.seat,
    required this.addressChanged,
    required this.openRoom,
  }) {
    unawaited(LeftEarly.load().then((at) {
      if (_disposed || at == null) return;
      _leftEarlyAt = max(at, _leftEarlyAt ?? at);
      _timeTheWait();
    }));
  }

  /// Who this device is to everyone else, as the front door has it now.
  final ({String name, Avatar avatar}) Function() who;

  /// The game this device is asking for, with the score a browser test
  /// asks for in place of the device's own (net/address.dart, `target`).
  final GameOptions Function() options;

  /// The name the others will see, asked for if this device has none:
  /// false when the person says not now.
  final Future<bool> Function() named;

  /// The front door's words, as it has them now.
  final AppLocalizations Function() words;

  /// Opens a table's [LiveController] over the front door; true when
  /// the end of game's Play again was pressed.
  final Future<bool?> Function(LiveController controller) seat;

  /// The room this device is in changed in a way the address says.
  final VoidCallback addressChanged;

  /// The room to open onto, from a shared link: the one in the address
  /// now, which is the room this device is in while it is in one, and
  /// none once it has left it.
  final String? Function() openRoom;

  final List<Uri> _relays = appRelays();
  Signer? _signer;
  Standing? _standing;

  /// Who this device is on the relays, once it has asked.
  Signer? get signer => _signer;

  /// This device's ratings, once the relays that answered have said.
  Standing? get standing => _standing;

  /// How long this device takes over a card, as it has measured itself
  /// (pace_store.dart). Nothing until it has played enough to know.
  Pace pace = Pace.fresh;

  /// What this device does with the others' pictures: the list of
  /// people whose pictures it does not show, and the check it runs on
  /// the rest (pictures.dart). Read once, carried to the table.
  Pictures? pictures;

  String? _error;

  /// What went wrong the last time, as the front door says it; null
  /// once a way in is being opened again.
  String? get error => _error;

  /// Says [why] at the door, where what went wrong is said.
  void say(String why) {
    _error = why;
    _changed();
  }

  /// Which way in is being opened, while it is being opened. Both are
  /// a relay connection away and both take a moment, and a spinner on
  /// the button that was not pressed is the door looking confused.
  Opening? _opening;
  Opening? get opening => _opening;
  bool get busy => _opening != null;

  /// Whether a way in is being opened, from before the name, age and
  /// terms are asked for until a relay answers. [busy] starts only once
  /// they have been.
  bool _entering = false;

  /// A relay is taking its time and the device is still waiting. Not an
  /// error — there is nothing to do about it but wait — so it is said
  /// quietly and it goes as soon as one answers.
  bool _slow = false;
  bool get slow => _slow;

  Room? _room;
  WaitingRoom? _queue;
  Room? get room => _room;
  WaitingRoom? get queue => _queue;
  RelayTransport? _transport;
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
  String? get cutOff => _relayNote ?? (deviceOffline() ? words().noRelayAnswered : null);

  /// Since when this device has been listening on the relays for who
  /// is online; null until they answer. The count is not shown for the
  /// first announcement period after, since the announcements are
  /// ephemeral and nobody is heard until they say so again.
  int? _listeningSinceMs;
  Timer? _onlineClock;

  StreamSubscription<TableSpec>? _queueSub;

  /// The seat this device is playing in (net/seat_store.dart): kept as
  /// the game goes, so that a reload comes back to it.
  SeatStore? _seats;

  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// When this device last left a game early (left_early.dart); null
  /// while there is no wait after it.
  int? _leftEarlyAt;
  Timer? _waitAfterLeaving;

  /// What is left of Play live's wait after a game left early: null when
  /// there is none. Playing alone and with friends never wait.
  Duration? get leftEarlyWait =>
      LeftEarly.left(atMs: _leftEarlyAt, nowMs: LeftEarly.nowMs(), wait: RemoteSettings.current.config.leftEarly);

  /// This device left a game early at [atMs]: kept, and waited out —
  /// unless the wait after it is over already, a game come back to long
  /// after it was left.
  void _leftEarly(int atMs) {
    if (LeftEarly.left(atMs: atMs, nowMs: LeftEarly.nowMs(), wait: RemoteSettings.current.config.leftEarly) == null) return;
    _leftEarlyAt = max(atMs, _leftEarlyAt ?? atMs);
    unawaited(LeftEarly.mark(atMs));
    _timeTheWait();
  }

  /// The door counts the wait down a second at a time, and once it is
  /// over lets the time go.
  void _timeTheWait() {
    _waitAfterLeaving?.cancel();
    _waitAfterLeaving = null;
    _clampToNow();
    if (leftEarlyWait == null) {
      if (_leftEarlyAt != null) unawaited(LeftEarly.clear());
      _leftEarlyAt = null;
    } else {
      _waitAfterLeaving = Timer.periodic(const Duration(seconds: 1), (_) {
        _clampToNow();
        if (leftEarlyWait == null) _timeTheWait();
        _changed();
      });
    }
    _changed();
  }

  /// A game left early at a time still ahead of the clock means the
  /// clock was set back since: the wait runs from now, rather than
  /// staying full until the clock catches up.
  void _clampToNow() {
    final at = _leftEarlyAt, now = LeftEarly.nowMs();
    if (at == null || at <= now) return;
    _leftEarlyAt = now;
    unawaited(LeftEarly.reset(now));
  }

  /// This device online to everyone (net/online.dart). The same, after
  /// the first.
  Online _online(Signer signer) => Online.on(_relays, signer, log: _onlineLog);

  /// Back from a reload in the middle of a game: straight back into the
  /// seat, if it can still be this device's. The table may have given it
  /// to a bot meanwhile, and then the table says so once it has caught
  /// this device up (live/live_page.dart).
  ///
  /// A seat away from for longer than a table waits was a game left
  /// early, when Play live seated it and somebody else sat there: it is
  /// waited out from when this device was last at the table.
  Future<void> _comeBack(Signer signer) async {
    final seats = _seats = await SeatStore.open();
    final kept = seats.load(gone: (seat) {
      final mine = seat.spec.seatOf(signer.publicKey);
      final others = [for (final (s, h) in seat.spec.seats.indexed) if (s != mine && h is HumanSeat) h];
      if (seat.strangers && mine != null && others.isNotEmpty) _leftEarly(seat.at);
    });
    if (kept == null || _disposed) return;
    if (kept.spec.seatOf(signer.publicKey) == null || (kept.spec.sealed && !dealReady)) return seats.clear();
    _toTable(kept.spec, kept.names, kept.avatars, journal: kept.journal, strangers: kept.strangers);
  }

  /// Online from the front door, not only from a table: this device is
  /// counted as soon as the app is open, and it sees who else is about.
  ///
  /// First, this device takes its account up (net/in_use.dart): the
  /// relay carries only the account's device in use, and one at a time.
  /// Asked to wait — the account is in a game on another device — it
  /// waits for the person's word, on the screen that asks for it.
  Future<void> goOnline() async {
    final signer = await Identity.signer();
    if (_disposed) return;
    _signer = signer;
    _changed();
    if (InUse.current.standing != Use.here) await InUse.current.open(signer);
    if (_disposed || InUse.current.shut || Online.current != null) return;
    unawaited(_comeBack(signer));
    unawaited(_online(signer).presence.ready.then((_) {
      if (_disposed) return;
      _listeningSinceMs = DateTime.now().millisecondsSinceEpoch;
      _changed();
    }));
    _onlineClock?.cancel();
    _onlineClock = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
  }

  /// Another device of the account took it up (net/in_use.dart): nothing
  /// live is left open here. The pool or the room goes, and presence and
  /// any table go with their own listeners (net/online.dart,
  /// live/live_page.dart).
  void stepBack() {
    _closeLobby();
    _listeningSinceMs = null;
    _onlineClock?.cancel();
    _onlineClock = null;
    _changed();
  }

  /// How many other people's devices are online, once this device has
  /// listened long enough to have heard everyone; null before. Others,
  /// so that alone is 0: the number is who there is to play with
  /// (packages/table, presence_relay.dart).
  ///
  /// And null while the device says it has no network: the beats it
  /// heard before are not who is here now, and it hears nobody new.
  int? get othersOnline {
    final since = _listeningSinceMs;
    final online = Online.current;
    if (since == null || online == null || deviceOffline()) return null;
    if (DateTime.now().millisecondsSinceEpoch - since < online.presence.everyMs + 1500) return null;
    return online.presence.online(withinMs: 15000).difference({online.presence.signer.publicKey}).length;
  }

  /// Ratings, from the relays that just answered — never from an
  /// address nobody has confirmed.
  Future<void> _loadStanding(List<Uri> relays, Signer signer) async {
    try {
      final standing = await Standing.load(relays, signer, account: Entitlement.current.licence?.account ?? signer.publicKey);
      if (_disposed) return;
      _standing = standing;
      _changed();
    } catch (_) {
      // The rating shows next time.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _closeLobby(address: false);
    _onlineClock?.cancel();
    _waitAfterLeaving?.cancel();
    super.dispose();
  }

  /// Out of the pool or the room, back to the front door.
  void leave() {
    _closeLobby();
    _changed();
  }

  /// Everything a waiting room or a room needs while it is open, shut:
  /// the pool, the room, the transport they share, and what its relays
  /// said of this device — a matched or started table opens its own.
  void _closeLobby({bool address = true}) {
    _queueSub?.cancel();
    _queueSub = null;
    _queue?.close();
    _queue = null;
    _waitClock?.cancel();
    _dropRoom(address: address);
    _refusalSub?.cancel();
    _refusalSub = null;
    _relayNote = null;
    _transport?.close();
    _transport = null;
  }

  /// Lets go of the room. Every way out of one — started, refused,
  /// left — is an answer to the room's own notification, and a
  /// [ChangeNotifier] may not be disposed inside one, so the disposal
  /// waits for the notification to finish.
  void _dropRoom({bool address = true}) {
    final room = _room;
    if (room == null) return;
    room.removeListener(_onRoom);
    scheduleMicrotask(room.dispose);
    _room = null;
    // Out of the room, so out of the address: a refresh from here is
    // the front door, not a table that has started or emptied. Not when
    // a table is opening over the door, which says where it is; the
    // address is the door's again when it is back on top.
    if (address) addressChanged();
  }

  /// Connects to the relays on [tag], or explains why not. Nothing
  /// goes near a relay without a name on it. Null, and nothing done,
  /// while a way in is being opened or one is open: a second press, or
  /// a room's link opening while Play live is asked for, would open a
  /// second wait beside the first.
  Future<RelayTransport?> _connect(String tag, Opening opening) async {
    if (_entering || _transport != null) return null;
    _entering = true;
    try {
      return await _open(tag, opening);
    } finally {
      _entering = false;
    }
  }

  Future<RelayTransport?> _open(String tag, Opening opening) async {
    // A device that says it has no network will not find a relay by
    // waiting forty seconds for one (net/network.dart): it is told now,
    // before a name is asked for or anything is opened.
    if (deviceOffline()) {
      _error = words().noRelayAnswered;
      _changed();
      return null;
    }
    if (!await named() || _disposed) return null;
    final relays = _relays;
    _opening = opening;
    _slow = false;
    _error = null;
    _changed();
    RelayTransport? transport;
    try {
      final signer = _signer ??= await Identity.signer();
      // The relay carries the account's device in use and no other: this
      // one, before anything is opened — unless the service has just
      // not answered, and then the relay says what it will.
      if (InUse.current.standing != Use.here && InUse.current.worthAsking) await InUse.current.open(signer);
      // And the account's picture now, and no other
      // (service/do/profile_pictures.mjs): a change made a moment ago goes
      // first, so that the picture this device puts out is the service's.
      await AccountProfile.current.settled();
      if (_disposed || InUse.current.shut) {
        _opening = null;
        _changed();
        return null;
      }
      transport = RelayTransport(relays: relays, signer: signer, table: tag, log: _relayLog, pinned: pinnedRelays(relays));
      unawaited(_refusalSub?.cancel());
      _refusalSub = transport.refusals.listen((r) {
        if (_disposed) return;
        _relayNote = r == null ? null : words().noRelayTakesEvents(r);
        _changed();
      });
      await waitForRelay(transport.ready, slow: () {
        if (_disposed) return;
        _slow = true;
        _changed();
      });
      if (_disposed) {
        transport.close();
        return null;
      }
      // A relay answered: from here on this device is online to
      // everyone.
      _online(signer);
      if (_standing == null) await _loadStanding(relays, signer);
      if (_disposed) {
        transport.close();
        return null;
      }
      _transport = transport;
      _opening = null;
      _slow = false;
      _changed();
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

  /// The connection did not come off: the sockets go, and the door
  /// says why rather than sitting on a spinner.
  void _fell(RelayTransport? transport, String Function(AppLocalizations l10n) why) {
    _refusalSub?.cancel();
    _refusalSub = null;
    transport?.close();
    if (_disposed) return;
    _opening = null;
    _slow = false;
    _error = why(words());
    _changed();
  }

  /// Every live table is sealed, and a device that cannot run the deal
  /// does not sit down (docs/explanation/fair-deal.md), nor one whose
  /// build names no house to seat it with. It says so at the door,
  /// rather than connecting to find out; true when it has.
  bool _withoutDeal() {
    if (dealReady && _house != null) return false;
    _error = dealReady ? words().roomOtherBuild : Room.noDeal(words());
    _changed();
    return true;
  }

  /// Into the pool the options ask for, and wait to be seated by the
  /// house (packages/table, matching.dart). Everyone in a pool wants the
  /// same game, so the score it plays to is part of the pool's own name.
  /// Not while the wait after a game left early runs: the door says so,
  /// and offers nothing.
  Future<void> play() async {
    if (livePaused || leftEarlyWait != null || _withoutDeal()) return;
    final options = this.options();
    final transport = await _connect(poolTag(options.pool, target: options.target), Opening.live);
    if (transport == null) return;
    final me = who();
    final queue = WaitingRoom(
      relay: transport,
      pool: options.pool,
      target: options.target,
      name: me.name,
      rating: (_standing?.mine ?? Rating.fresh).shown,
      // What this device has measured of its own play, so it is seated
      // with people who play at about its speed (pace_store.dart).
      pace: pace.stated,
      // Whose device this is, by the service's word: a seating names
      // every seat's account with it, and every seat checks them all.
      licence: Entitlement.current.licence,
      // The one key a seating is taken from, and the house every table
      // it seats names.
      house: _house,
      avatar: me.avatar.isDefault ? null : me.avatar.toJson(withPicture: false),
      picture: me.avatar.picture == null ? null : base64Encode(me.avatar.picture!),
    );
    _queueSub = queue.seated.listen((spec) {
      if (_disposed) return;
      // The seating carried each seat's icon and colour; pictures came
      // on their own, by key.
      final avatars = <int, Avatar>{};
      for (var s = 0; s < spec.seats.length; s++) {
        final h = spec.seats[s];
        if (h is! HumanSeat) continue;
        if (h.key == _signer!.publicKey) {
          avatars[s] = who().avatar;
          continue;
        }
        final chosen = Avatar.fromJson(queue.seatAvatars[s], withPicture: false);
        final picture = queue.pictures[h.key];
        avatars[s] = picture == null ? chosen : chosen.copyWith(picture: Avatar.fromJson({'picture': picture}).picture);
      }
      _toTable(spec, queue.seatNames, avatars, again: play, strangers: true);
    });
    // The longest this queue has been willing to wait past the pool's
    // own wait, kept once chosen: taking bots after waiting for a person
    // comes back to the next round, not to a deadline already passed.
    var patience = 0;
    _waitClock = Timer.periodic(const Duration(seconds: 1), (_) {
      // Bots take every seat still empty at ten seconds, so a device
      // the house can hear is seated a round or two after that, and
      // one woken for the pool a few seconds later. One still waiting
      // at the far deadline is one the house and it are not hearing
      // each other through — it went offline, or its relays did — and
      // the spinner would turn for ever. So back to the door, saying
      // why.
      // Counted from when bots were due, for one who chose to wait
      // for a person.
      patience = max(patience, queue.botsAfterMs - queue.poolBotsAfterMs);
      if (DateTime.now().millisecondsSinceEpoch - queue.since >= stopWaiting.inMilliseconds + patience) {
        _closeLobby();
        _error = words().noRelayAnswered;
        _changed();
        return;
      }
      _changed();
    });
    _queue = queue;
    _changed();
  }

  /// Waits up to five minutes for a person rather than bots at ten
  /// seconds, and tells the service, so the people who run the game
  /// hear someone is waiting (service/functions/alerts.mjs).
  void waitForPerson() {
    final queue = _queue;
    final signer = _signer;
    // Offered only at an empty pool (home_page.dart, _WaitingView), and
    // only then are we told (the privacy policy): somebody may have
    // arrived since.
    if (queue == null || signer == null || queue.present.length > 1) return;
    queue.waitForPerson();
    _changed();
    unawaited(askHandler('waiting', signer, {'pool': queue.pool, 'target': queue.target}, what: '${queue.pool} ${queue.target}'));
  }

  /// The seated table is its own tag on the relay, whose object is the
  /// table's referee: a line to it for the table's log, the table's
  /// other lanes beside it — who is watching, and the players' reactions
  /// — and the live page over the front door, so leaving the table
  /// comes back there.
  ///
  /// [again] begins another game the way this one began, for the end
  /// of game's Play again. [strangers] is a table Play live seated,
  /// whose game left early is waited out (left_early.dart).
  void _toTable(TableSpec spec, Map<int, String> names, Map<int, Avatar> seatAvatars,
      {TableJournal? journal, VoidCallback? again, bool strangers = false}) {
    // Every name trimmed and cut as this device keeps its own
    // (identity.dart): the others' come as their devices sent them, and
    // a modified build can send one of any length, or with control
    // characters in it.
    final seatNames = {for (final MapEntry(:key, :value) in names.entries) key: Identity.nameOf(value)};
    final signer = _signer!;
    final relays = _relays;
    final line = RelayLine(relays: relays, signer: signer, table: spec.id, log: _debugging ? (l) => debugPrint('line: $l') : null);
    // The watch lane and the reactions beside it, and nothing of the
    // table's own, which is the line's (packages/table, watch.dart,
    // reactions.dart).
    final lanes = RelayTransport(relays: relays, signer: signer, table: spec.id, log: _relayLog, pinned: pinnedRelays(relays), watchOnly: true);
    final ledger = _standing?.ledger ?? Ledger();
    final controller = LiveController(
      spec: spec,
      seatNames: seatNames,
      seatAvatars: seatAvatars,
      signer: signer,
      line: line,
      reactions: lanes,
      crypto: dealCrypto,
      dealWorker: dealWorker,
      ratingOf: spec.rated ? (id) => ledger.of(id) : null,
      // The house's word on the finished game, folded here as the ledger
      // folds it off the relay (net/standing.dart): the game's own sheet
      // says what it did to your rating, and the door behind the table
      // has the new rating on it when you get there. The house says it on
      // the results tag itself.
      onResult: ledger.apply,
      pictures: pictures,
      canPlayAgain: again != null,
      strangers: strangers,
      // What the table's rules make of the log, for a driven build's
      // console: the browser suites read why a table went as it did
      // (e2e/drive.mjs).
      trace: _debugging ? (l) => debugPrint('table: $l') : null,
      journal: _seats?.keep(spec, seatNames, seatAvatars, journal: journal, strangers: strangers),
    );
    // A game left early, by the player's word or the table's, is
    // waited out, from the moment this device knows it — unless the
    // account went to another device, which is the player using it
    // there, not leaving (net/in_use.dart).
    var leftEarly = false;
    controller.addListener(() {
      if (leftEarly || !controller.leftEarly || InUse.current.shut) return;
      leftEarly = true;
      _leftEarly(LeftEarly.nowMs());
    });
    // Kept for coming back to while the seat is this device's; let go
    // once the game is over or the seat is not (net/seat_store.dart).
    var hereAt = 0;
    controller.addListener(() {
      final seats = _seats;
      if (seats == null) return;
      if (controller.client.done || (controller.client.mySeat != null && !controller.client.amSeated)) {
        seats.clear();
        // Over, or out of it: the account no longer sits at this table,
        // and the service is told now rather than once the page is left,
        // so the game — kept now — can be looked at from its end
        // (net/game_records.dart) while the page still shows it.
        if (InUse.current.seatedTable == spec.id && !InUse.current.shut) InUse.current.seatedAt(null);
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - hereAt < _seatSavedEvery.inMilliseconds) return;
      hereAt = now;
      seats.here();
    });
    // Anyone with the table's address can watch it being played: one
    // seated player's device answers them with what everyone at the
    // table sees (packages/table, watch.dart).
    final said = words();
    final watch = WatchBroadcast(
      heard: lanes.watch,
      say: lanes.sayWatch,
      view: () => WatchedTable.of(controller.client, [
        for (final (s, holder) in controller.client.holders.indexed)
          switch (holder) {
            BotSeat(:final persona) => persona.name,
            HumanSeat() => seatNames[s] ?? said.seatNumber(s + 1),
          },
      ]),
      answering: () => WatchBroadcast.answers(controller.client, signer.publicKey),
      // Nobody of an account seated here watches it: their own game.
      seated: spec.accounts,
    );
    controller.addListener(watch.changed);
    // What this device measured of its own play goes on the device and
    // nowhere else (pace_store.dart). Folded once: when the game is
    // over, so that Play again asks with it, or else when the player
    // is off the table, since a game left early is still cards this
    // player took their own time over.
    var paced = false;
    void foldPace() {
      if (paced) return;
      paced = true;
      unawaited(PaceStore.fold(controller.myCardMs).then((folded) {
        if (_disposed) return;
        pace = folded;
        _changed();
      }));
    }

    controller.addListener(() {
      if (controller.client.done) foldPace();
    });
    // The game, kept for anyone to look at afterwards by its address
    // (net/game_records.dart): every player's device sends it, and the
    // first is kept. Once the house's word on how it came out is in the
    // log, which a kept game is checked against (packages/table,
    // record.dart); a game that failed has none, and is kept as it ends.
    var kept = false;
    controller.addListener(() {
      final c = controller.client;
      if (kept || !c.done || (c.rules.result == null && c.state != TableState.failed)) return;
      kept = true;
      unawaited(keepGame(signer, GameRecord.of(c, names: seatNames)).then((taken) {
        if (!taken) debugPrint('record: not kept');
      }));
    });
    _closeLobby(address: false);
    _changed();
    // At a table, as the service is told: another device of the account
    // asks before taking the account from a game (net/in_use.dart).
    // Cleared on the way back to the front door, however the table
    // ended.
    InUse.current.seatedAt(spec.id);
    // Off the table, whichever way: by one of its own ways out, which
    // the page closes with, or by a browser's Back, which closes
    // nothing here, so the table's controller says so as it goes.
    var off = false;
    void offTheTable() {
      if (off) return;
      off = true;
      foldPace();
      if (!InUse.current.shut) InUse.current.seatedAt(null);
      watch.close();
      lanes.close();
      // Off the table by choice: nothing to come back to.
      _seats?.clear();
    }
    controller.onClosed = offTheTable;
    unawaited(seat(controller).whenComplete(offTheTable).then((playAgain) {
      if (playAgain == true && !_disposed) again?.call();
    }));
  }

  /// Into the room this device arrived at by a link, or a new one of
  /// its own: nobody types a code, so a room is either started here or
  /// opened from a link someone sent. Whoever is there is the table,
  /// and the first to arrive is nobody special. [same] is the room a
  /// game just ended in, entered again for another.
  Future<void> enter({String? same}) async {
    if (livePaused || _withoutDeal()) return;
    final code = same ?? openRoom() ?? Room.newCode();
    final transport = await _connect(code, Opening.friends);
    if (transport == null) return;
    try {
      final me = who();
      final room = Room.enter(
        relay: transport,
        code: code,
        name: me.name,
        avatar: me.avatar,
        target: options().target,
        timing: RemoteSettings.current.config.table,
        house: _house,
        licence: Entitlement.current.licence,
        // Ten seconds, unless the address asks for longer and is
        // allowed to (net/address.dart).
        startAfter: roomWait(Uri.base, standard: waits.roomStart),
      );
      room.addListener(_onRoom);
      _room = room;
      _changed();
      // The room is its link, and the link is in the address bar while
      // this device is in it (net/address.dart).
      addressChanged();
    } catch (e) {
      // The room could not be made from what the relays hold under its
      // code: nothing of it stays open.
      _closeLobby();
      if (_disposed) return;
      _error = words().couldNotConnect('$e');
      _changed();
    }
  }

  void _onRoom() {
    final room = _room;
    if (room == null || _disposed) return;
    final spec = room.spec;
    if (room.refusal != null) {
      _closeLobby();
      _error = Room.said(room.refusal!, words());
      _changed();
      return;
    }
    if (spec != null) {
      if (!room.seated) {
        // A table under this code started without a seat for this
        // device: back to the front door, where the line can be read.
        _closeLobby();
        _error = words().tableFilledWithoutYou;
        _changed();
        return;
      }
      room.removeListener(_onRoom);
      final code = room.code;
      _toTable(spec, room.seatNames, room.seatAvatars, again: () => enter(same: code));
      return;
    }
    _changed();
  }
}
