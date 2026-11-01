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
/// This is also where a device comes online: it says it is here from
/// the front door, not only from a table (live/lobby.dart,
/// net/online.dart).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'activate_page.dart';
import 'age_gate.dart';
import 'avatar.dart';
import 'build_info.dart' show buildDate, reloadPage;
import 'entitlement.dart';
import 'feedback_page.dart';
import 'game_options.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'live/lobby.dart';
import 'net/account_profile.dart';
import 'net/address.dart';
import 'net/buying.dart';
import 'net/copy.dart';
import 'net/household.dart';
import 'net/in_use.dart';
import 'net/online.dart';
import 'net/remote_config.dart';
import 'net/room.dart';
import 'net/share.dart';
import 'net/standing.dart' show Standing;
import 'options_sheet.dart';
import 'pace_store.dart';
import 'pages.dart';
import 'pictures.dart';
import 'profile_page.dart';
import 'subscribe_page.dart';
import 'table_page.dart';
import 'theme.dart';
import 'tutorial.dart';
import 'ui/doorway.dart';
import 'ui/folding_heart.dart';
import 'ui/header.dart';
import 'ui/player_icon.dart';
import 'ui/update_pill.dart';

/// The deal a solo game starts from, for a browser test that needs a
/// particular one (`?e2e&seed=156`); in a build not being driven, never.
final _dealtFrom = driven(Uri.base) ? int.tryParse(Uri.base.queryParameters['seed'] ?? '') : null;

/// The score the games started here play to, when a browser test asks
/// for another (`?e2e&target=1`, net/address.dart); otherwise never —
/// the device's own choice, which the door still shows.
final _playsTo = targetIn(Uri.base);

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

  /// The game this device is asking for, off the device and back onto
  /// it when it changes (game_options.dart).
  GameOptions _options = const GameOptions();

  /// The way from here to a live table (live/lobby.dart): the relays, the
  /// pool or the room, and the table they open.
  late final Lobby _lobby;

  void _lobbyChanged() {
    if (mounted) setState(() {});
  }

  /// Back from a checkout and waiting for the licence it bought: said
  /// so, where the way to buy would otherwise sit looking as if nothing
  /// had happened. [_paidWaiting] is the wait run out with no licence
  /// yet — the payment went through, the webhook has not.
  late bool _finishing = widget.justBought;
  bool _paidWaiting = false;

  /// The heart at the top, held by a key of its own: the door, the
  /// waiting screen and the room put it in different places, and it is
  /// the same heart in all three — a fold part way through carries
  /// across the change instead of starting over (ui/doorway.dart).
  final _heart = GlobalKey();

  /// Whether this device goes online to everyone from here: it plays
  /// live, and the operator has not paused live play.
  bool get _goesOnline => widget.online && liveOpen && !livePaused;

  @override
  void initState() {
    super.initState();
    _lobby = Lobby(
      who: () => (name: _name, avatar: _avatar),
      options: () => _options.copyWith(target: _playsTo),
      named: () async => await _storeLets() && await _named() != null && await _agreed(),
      words: () => context.l10n,
      seat: (controller) => context.push<bool>(located(livePath), extra: controller),
      addressChanged: _showAddress,
      openRoom: () => widget.openRoom,
    )..addListener(_lobbyChanged);
    _restore();
    Pictures.load().then((p) {
      if (mounted) _lobby.pictures = p;
    });
    // Live play can open under this screen — a subscription bought on
    // the way back from a checkout, a licence the service was slow to
    // answer for — and when it does the door opens with it.
    Entitlement.current.addListener(_licensed);
    RemoteSettings.current.addListener(_configured);
    InUse.current.addListener(_inUse);
    // Who this device is can change under this screen: another device
    // of the account changed the profile (net/account_profile.dart).
    AccountProfile.current.addListener(_reprofiled);
    // A device that cannot play live has no business in the count of
    // who is here — nor one whose live play the operator has paused.
    if (_goesOnline) _lobby.goOnline();
    // Neither of these is the relays, which is what `online` is about:
    // they are one call to the service each, and a test stands its own
    // behind that (net/household.dart).
    if (widget.justBought) unawaited(_justBought());
    if (widget.openClaim != null) unawaited(_arriving());
  }

  /// The router, listened to for the moment this screen is on top again
  /// (router.dart): a page closed over it, or a game ended.
  GoRouter? _router;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (identical(router, _router)) return;
    _router?.routerDelegate.removeListener(_moved);
    _router = router?..routerDelegate.addListener(_moved);
  }

  bool get _onTop => _isHome(_router?.state.uri.path);

  static bool _isHome(String? path) => path == '/' || (path?.startsWith('/room/') ?? false);

  bool _wasOnTop = true;

  void _moved() {
    final onTop = _onTop;
    if (onTop && !_wasOnTop) unawaited(_back());
    _wasOnTop = onTop;
  }

  /// On top again. Who this device is may have changed on a page over
  /// this one — the profile keeps itself — and the address is this
  /// screen's again: in the room this device is in, or none.
  Future<void> _back() async {
    final name = await Identity.name();
    final avatar = await Identity.avatar();
    final learning = await Learning.offered();
    if (!mounted) return;
    setState(() {
      _name = Identity.playable(name);
      _avatar = avatar;
      _offerLearning = learning;
    });
    _showAddress();
  }

  /// Whether the door offers the tutorial under Play solo: to a device
  /// that has not opened it and has finished no game alone
  /// (tutorial.dart). The menu has it for anyone.
  bool _offerLearning = false;

  void _learn() => context.push<void>(located(soloPath), extra: const SoloGame(learning: true));

  /// The account's profile taken over this device's: shown at once, and
  /// what the next room or table is told.
  Future<void> _reprofiled() async {
    final name = await Identity.name();
    final avatar = await Identity.avatar();
    if (!mounted) return;
    setState(() {
      _name = Identity.playable(name);
      _avatar = avatar;
    });
  }

  /// The address, as this screen says it: its room, or none, and [drop]
  /// taken out — a mark a round trip put there (the code a claim came
  /// with, the `bought` a checkout came back with), which a refresh
  /// should not act on twice. Not a place in the history: entering and
  /// leaving a room is not something to go back to. Only while this
  /// screen is the one showing; a page over it says where it is.
  void _showAddress({Set<String> drop = const {}}) {
    final router = _router;
    if (!mounted || router == null || !_onTop) return;
    final at = router.state.uri;
    final room = _lobby.room;
    final query = Map<String, String>.of(at.queryParameters)..removeWhere((k, _) => drop.contains(k));
    final to = Uri(path: room == null ? '/' : roomPath(room.code), queryParameters: query.isEmpty ? null : query).toString();
    if (to == at.toString()) return;
    Router.neglect(context, () => router.go(to));
  }

  Future<void> _goAbout() => openPage<void>(context, AppPage.about);

  /// Arrived by a code another device showed (docs/explanation/service.md): this
  /// device joins that subscription and is given a licence of its own.
  Future<void> _arriving() async {
    final code = widget.openClaim;
    if (code == null) return;
    // Asked first. A link is anybody's to send, and a code spent on
    // opening it would put this device in whatever household sent it,
    // without a word to its owner (docs/explanation/security-model.md).
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final join = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(dialog.l10n.joinHouseholdTitle),
        content: Text(dialog.l10n.joinHouseholdBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(dialog.l10n.notNow)),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(dialog.l10n.join)),
        ],
      ),
    );
    if (join != true) {
      _forget('claim');
      return;
    }
    if (!mounted) return;
    // Checked against the service this app is standing behind, which
    // is the entitlement's to name and not a constant's: a test stands
    // its own there, and so does the browser suite's rig.
    final said = await claimCode(await Identity.signer(), code, service: Entitlement.current.service);
    if (!mounted) return;
    if (said.answer != null) {
      await Entitlement.current.adopt(said.answer!);
    } else {
      _lobby.say(said.refusal!.say(context.l10n));
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _showAddress(drop: {name}));
  }

  /// Live play opened, or shut, under this screen.
  void _licensed() {
    if (!mounted) return;
    setState(() {});
    if (_goesOnline && Online.current == null) _lobby.goOnline();
  }

  /// Another device of the account took it up, or this one took it back,
  /// or the account is suspended (net/in_use.dart). Shut, nothing live is
  /// left open here: the pool or the room goes, and presence and any
  /// table go with their own listeners (net/online.dart,
  /// live/live_page.dart). Taken back, this device comes online again.
  void _inUse() {
    if (!mounted) return;
    if (InUse.current.shut) {
      _lobby.stepBack();
      return;
    }
    setState(() {});
    if (_goesOnline && Online.current == null && InUse.current.standing == Use.here) _lobby.goOnline();
  }

  /// The operator said something new. A pause shuts the doors from here
  /// on and leaves whatever is already under way alone: a game being
  /// played goes on. A pause lifted opens them again.
  void _configured() {
    if (!mounted) return;
    setState(() {});
    if (_goesOnline && Online.current == null) _lobby.goOnline();
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
    if (!mounted) return;
    setState(() {
      _finishing = false;
      _paidWaiting = !liveOpen;
    });
  }

  /// Who this device is and what game it asks for, off the device. In
  /// that order: a link opens a room as soon as the name is known, and
  /// the room is started with the options.
  Future<void> _restore() async {
    final options = await GameOptions.load();
    final avatar = await Identity.avatar();
    final name = await Identity.name();
    final pace = await PaceStore.load();
    final learning = await Learning.offered();
    if (!mounted) return;
    setState(() {
      _options = options;
      _avatar = avatar;
      _name = Identity.playable(name);
      _lobby.pace = pace;
      _offerLearning = learning;
    });
    // Here by a link: straight into the room — unless live play is
    // locked, which a link does not open. A device with no name yet is
    // asked for one on the way in.
    if (liveOpen && !livePaused && widget.openRoom != null) await _lobby.enter();
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_moved);
    Entitlement.current.removeListener(_licensed);
    RemoteSettings.current.removeListener(_configured);
    InUse.current.removeListener(_inUse);
    AccountProfile.current.removeListener(_reprofiled);
    _lobby
      ..removeListener(_lobbyChanged)
      ..dispose();
    super.dispose();
  }

  /// Who you are here, and how you have done: the name the others see,
  /// the face they see it on, and what the games say. The first two are
  /// kept on the device as soon as the page is left.
  Future<void> _editProfile() async {
    // The profile keeps what it is left with on the device itself; this
    // screen reads it back when it is on top again ([_back]), however
    // the page was opened. Waited for here as well, for [_named], which
    // goes on only once there is a name.
    await showProfile(context, stats: statsOnThisDevice(standing: _lobby.standing, online: widget.online));
    if (mounted) await _back();
  }

  /// Whether the phone's store lets this player play live
  /// (age_gate.dart): asked first, so that a player it does not let is
  /// asked for neither a name nor the terms.
  Future<bool> _storeLets() => storeLetsPlayLive(context);

  /// The name the others will see, asked for if this device has none:
  /// nothing is played live without one, and the place to give it is
  /// the profile. Null when the sheet comes back without a name, which
  /// is the player saying not now.
  Future<String?> _named() async {
    if (_name.isNotEmpty) return _name;
    await _editProfile();
    return _name.isEmpty ? null : _name;
  }

  /// The terms agreed to, asked for once on this device before its
  /// name and picture first go out at a live table: the app stores ask
  /// for this before anyone publishes anything. Subscribing is agreeing
  /// too (subscribe_page.dart), but a device brought into an account
  /// with a code or a sign-in never saw that. False when the player
  /// says not now.
  Future<bool> _agreed() async {
    if (await Identity.agreedToTerms() != null) return true;
    if (!mounted) return false;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (dialog) {
        final l10n = dialog.l10n;
        return AlertDialog(
          title: Text(l10n.liveAgreeTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.liveAgreeBody),
              const SizedBox(height: 8),
              TextButton(onPressed: () => openLink(legalPage('terms')), child: Text(l10n.termsOfUse)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.notNow)),
            FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(l10n.liveAgree)),
          ],
        );
      },
    );
    if (agreed != true) return false;
    await Identity.agreeToTerms(DateTime.now());
    return true;
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
    await copyText(link.toString());
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.linkCopied, textAlign: TextAlign.center), duration: const Duration(milliseconds: 1600), width: 200));
  }

  @override
  Widget build(BuildContext context) {
    final room = _lobby.room;
    final queue = _lobby.queue;
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
                      tagline: context.l10n.tagline,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          queue != null
                              ? _WaitingView(
                                  queue: queue,
                                  onCancel: _lobby.leave,
                                  onWaitForPerson: _lobby.waitForPerson,
                                  onPlayWithBots: () => setState(queue.playWithBots),
                                )
                              : room == null
                                  ? _entry()
                                  : RoomView(
                                      room: room,
                                      ledger: _lobby.standing?.ledger,
                                      pictures: _lobby.pictures,
                                      onLeave: _lobby.leave,
                                      onShare: () => _share(room.code),
                                    ),
                          if (_lobby.cutOff != null && (queue != null || room != null)) ...[
                            const SizedBox(height: 14),
                            Text(_lobby.cutOff!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
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
            // the way to it, and the menu saying it again would be a
            // second way to the one page.
            if (liveOpen)
              MenuAction(l10n.subscription, icon: Icons.card_membership_outlined, onSelected: () => showSubscribe(context)),
            // Not subscribed here: a subscription bought on another
            // device, or a backup code from the email, brings it in.
            if (!liveOpen)
              MenuAction(l10n.activateSubscription, icon: Icons.key_outlined, onSelected: () => showActivate(context)),
            MenuAction(l10n.learnToPlay, icon: Icons.school_outlined, onSelected: _learn),
            MenuAction(l10n.tellUsWhatsBroken, icon: Icons.feedback_outlined, onSelected: () => showFeedback(context)),
            MenuAction(l10n.about, icon: Icons.info_outline, onSelected: _goAbout),
          ],
        ),
        const Spacer(),
        ProfileButton(
          name: _name,
          // The account's colour, the one the table shows.
          seed: Entitlement.current.licence?.account ?? _lobby.signer?.publicKey ?? '',
          avatar: _avatar,
          rating: ProfileButton.shown(_lobby.standing),
          height: _chromeHeight,
          onTap: _editProfile,
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
        FilledButton(
          onPressed: () => context.push<void>(located(soloPath), extra: SoloGame(target: _playsTo ?? _options.target, seed: _dealtFrom)),
          style: _primary(),
          child: Text(l10n.playSolo, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
        ),
        if (_offerLearning) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: _learn,
            style: TextButton.styleFrom(foregroundColor: Palette.gold),
            child: Text(l10n.learnToPlayOffer, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
          ),
        ],
        // Live play, as the operator has it now: paused for everyone, open
        // here, or offered — unless the paid tier is not being offered,
        // and then a device without it is not shown it.
        if (livePaused) ...[
          const SizedBox(height: 16),
          const _LivePaused(),
        ] else if (liveOpen) ...[
          const SizedBox(height: 16),
          _live(),
        ] else if (Entitlement.current.live && InUse.current.elsewhere) ...[
          // Live play is this account's, and open on another device:
          // the way to take it back.
          const SizedBox(height: 16),
          _LiveElsewhere(onTap: () async => InUse.current.open(await Identity.signer())),
        ] else if (_finishing || _paidWaiting) ...[
          const SizedBox(height: 16),
          _Finishing(waiting: _finishing),
        ] else if (RemoteSettings.current.config.offer) ...[
          const SizedBox(height: 16),
          _LiveLocked(onTap: () => showSubscribe(context)),
        ],
        if (_lobby.slow) ...[
          const SizedBox(height: 14),
          Text(l10n.stillLookingForRelay, textAlign: TextAlign.center, style: const TextStyle(color: Palette.chromeDim, fontSize: 13)),
        ],
        if (_lobby.error != null) ...[
          const SizedBox(height: 14),
          Text(_lobby.error!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
        ],
      ],
    );
  }

  /// Live play: the game being asked for, and the two ways into one —
  /// whoever is waiting, or the people you send the link to.
  Widget _live() {
    final l10n = context.l10n;
    // A game left early is waited out before Play live seats this device
    // again (live/left_early.dart); the rest of the door is as ever.
    final wait = _lobby.leftEarlyWait;
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
              Expanded(child: LiveGameLine(target: _options.target, pool: _options.pool, others: _lobby.othersOnline)),
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
          const SizedBox(height: 8),
          _PlayLive(others: _lobby.othersOnline, busy: _lobby.opening == Opening.live, disabled: _lobby.busy || wait != null, onTap: _lobby.play),
          if (wait != null) ...[
            const SizedBox(height: 6),
            Text(
              l10n.leftEarlyWait(_clock((wait.inMilliseconds + 999) ~/ 1000)),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Palette.chromeDim, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 10),
          // The same gold as the rest: two ways into a live game, and
          // neither is the lesser of them.
          FilledButton(
            onPressed: _lobby.busy ? null : _lobby.enter,
            style: _primary(),
            child: _Trying(busy: _lobby.opening == Opening.friends, label: l10n.playFriends, weight: FontWeight.w700, size: 15.5),
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

/// The way into your profile, in the top right: how you look to the
/// others, and just left of it your rating once there is one. A finger
/// has the number and the picture as one button, since the profile is
/// where both are said in full. A screen reader has them as what they
/// are: the rating said, and the picture the button, named as ever.
class ProfileButton extends StatelessWidget {
  const ProfileButton(
      {super.key, required this.name, required this.seed, required this.avatar, required this.rating, required this.onTap, this.height = 44});

  final String name;
  final String seed;
  final Avatar avatar;

  /// None before the standings are in or before a rated game ([shown]).
  final Rating? rating;
  final VoidCallback onTap;
  final double height;

  /// Your rating as the corner shows it: once the standings are in and
  /// a rated game has made one. Before that it is the 1500 everyone
  /// starts at, which the profile does not show as earned either
  /// (profile_page.dart).
  static Rating? shown(Standing? standing) {
    if (standing == null || standing.ledger.gamesOf(standing.me) == 0) return null;
    return standing.mine;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rating = this.rating;
    return InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      // The ink is the tap a finger makes, and says nothing of its own:
      // otherwise it is a second, nameless button around the first.
      excludeFromSemantics: true,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(left: rating == null ? 8 : 12, right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (rating != null) ...[
                Semantics(
                  container: true,
                  label: l10n.ratedSpoken(rating.shown, flag(rating.provisional)),
                  child: ExcludeSemantics(
                    child: Text(
                      '${rating.shown}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                        color: Palette.chrome,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Semantics(
                container: true,
                button: true,
                label: l10n.yourProfile,
                onTap: onTap,
                child: ExcludeSemantics(
                  child: SizedBox(
                    height: height,
                    child: Center(child: PlayerIcon(name: name.isEmpty ? '?' : name, seed: seed, avatar: avatar, size: 32)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The game the live buttons are about to ask for, and how many other
/// people are online to play it with, once the relays have said. The
/// Play live button says the count to a screen reader, so it is not
/// said twice.
class LiveGameLine extends StatelessWidget {
  const LiveGameLine({super.key, required this.target, required this.pool, required this.others});

  final int target;
  final String pool;

  /// Other people online (live/lobby.dart); null until it is known.
  final int? others;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final game = l10n.gameLine(target, pool);
    final n = others;
    return Text.rich(
      TextSpan(text: game, children: [
        if (n != null)
          TextSpan(
            text: ' · ${l10n.onlineCount(n)}',
            style: const TextStyle(fontWeight: FontWeight.w500, color: Palette.chromeDim),
          ),
      ]),
      semanticsLabel: game,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Palette.chrome, letterSpacing: 0.2),
    );
  }
}

/// Into a live game. A screen reader hears how many are online with
/// the button: the count is the reason to press it now or to come back
/// later, so it is said where the pressing happens. The eye has it on
/// the line above ([LiveGameLine]).
class _PlayLive extends StatelessWidget {
  const _PlayLive({required this.others, required this.busy, required this.disabled, required this.onTap});

  /// Other people online; null before the relays have been heard from.
  final int? others;

  /// Whether this is the one being opened, which is what the spinner
  /// says; [disabled] is either of them being opened, which is what
  /// stops a second press.
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final n = others;
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
            ],
          ),
        ),
      ),
    );
  }
}

/// Back from paying, before the licence is here: a spinner while it is
/// asked for, and once the asking has run out, word that the payment
/// went through and live play opens when it reaches us.
class _Finishing extends StatelessWidget {
  const _Finishing({required this.waiting});

  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          if (waiting) ...[
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Palette.gold)),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Text(
              waiting ? l10n.finishingPurchase : l10n.paidLiveSoon,
              style: const TextStyle(fontSize: 14, height: 1.4, color: Palette.chrome),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live play, not open here. The padlock is not the point: what live
/// play is and what it costs is, and the way to it — gold, like every
/// way on, but drawn rather than filled: Play solo is what the door is
/// for, and two filled buttons of one gold on one screen ask the eye
/// to choose before it has read either.
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
              Text(l10n.pricePerYear(priceShown),
                  style: const TextStyle(fontSize: 13, color: Palette.chrome, fontWeight: FontWeight.w600)),
            ],
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

/// Live play, open on another device of the account (net/in_use.dart):
/// said where the buttons were, with the way to take it back here.
class _LiveElsewhere extends StatelessWidget {
  const _LiveElsewhere({required this.onTap});

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
          Text(l10n.livePlay,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.chrome, letterSpacing: 0.2)),
          const SizedBox(height: 4),
          Text(l10n.liveOpenElsewhere, style: const TextStyle(fontSize: 12, height: 1.4, color: Palette.chromeDim)),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onTap,
            style: _HomePageState._secondary(),
            child: Text(l10n.useItHere, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
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
/// window — and, to a build older than the one asked for, that it is;
/// and a change to the terms or the privacy policy that matters to
/// subscribers, with a link to it, until it is dismissed. Nothing at
/// all when there is nothing to say.
class OperatorNotes extends StatefulWidget {
  const OperatorNotes({super.key, this.published = buildDate});

  /// The day this build was made: the build's own, unless a test says.
  final String published;

  @override
  State<OperatorNotes> createState() => _OperatorNotesState();
}

class _OperatorNotesState extends State<OperatorNotes> {
  /// Where the changes this device dismissed are kept, by id.
  static const _dismissedKey = 'notices_dismissed';

  /// The changes dismissed here (LegalNotice.id); null until read, and
  /// none is shown till then, so one dismissed does not flash back.
  Set<String>? _dismissed;

  @override
  void initState() {
    super.initState();
    unawaited(SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _dismissed = {...?prefs.getStringList(_dismissedKey)});
    }));
  }

  Future<void> _dismiss(Iterable<LegalNotice> notices) async {
    final dismissed = {...?_dismissed, for (final n in notices) n.id};
    setState(() => _dismissed = dismissed);
    await (await SharedPreferences.getInstance()).setStringList(_dismissedKey, dismissed.toList());
  }

  /// [changes] in a few words: which documents changed.
  static String _changed(AppLocalizations l10n, List<LegalNotice> changes) {
    final documents = {for (final c in changes) c.document};
    if (documents.length > 1) return l10n.changedBoth;
    return documents.single == 'terms' ? l10n.changedTerms : l10n.changedPrivacy;
  }

  /// What each of [changes] is, with a link to the whole document.
  void _showChanges(List<LegalNotice> changes) {
    unawaited(showDialog<void>(
      context: context,
      builder: (dialog) {
        final l10n = dialog.l10n;
        return AlertDialog(
          title: Text(l10n.whatChanged),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final change in changes) ...[
                  Text(change.document == 'terms' ? l10n.termsOfUse : l10n.privacyPolicy, style: Theme.of(dialog).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(change.summary.inLanguage(l10n.localeName)),
                  TextButton(onPressed: () => openLink(legalPage(change.document)), child: Text(l10n.readInFull)),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(MaterialLocalizations.of(dialog).closeButtonLabel)),
          ],
        );
      },
    ));
  }

  // Listening for itself: it is a const widget in the door's tree, which
  // a rebuild of the door passes over as unchanged.
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: RemoteSettings.current, builder: (context, _) => _notes(context));

  Widget _notes(BuildContext context) {
    final l10n = context.l10n;
    final config = RemoteSettings.current.config;
    final notice = config.banner;
    final dismissed = _dismissed;
    // The changes not dismissed here, as one line: what each says is a
    // tap away, and one tap dismisses them all.
    final changes = dismissed == null ? const <LegalNotice>[] : [...config.notices.where((n) => !dismissed.contains(n.id))];
    final lines = <Widget>[
      if (notice != null) _line(notice.text.inLanguage(l10n.localeName), notice.warning ? Palette.danger : Palette.gold),
      if (config.updateDue(widget.published))
        _line(config.updateText?.inLanguage(l10n.localeName) ?? (kIsWeb ? l10n.updateDueWeb : l10n.updateDueApp), Palette.gold,
            action: kIsWeb ? TextButton(onPressed: reloadPage, child: Text(l10n.reload)) : null),
      if (changes.isNotEmpty)
        _line(
          _changed(l10n, changes),
          Palette.gold,
          action: Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(onPressed: () => _showChanges(changes), child: Text(l10n.whatChanged)),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: Palette.chromeDim,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => _dismiss(changes),
            ),
          ]),
        ),
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

/// Waiting to be seated: a round every five seconds, and bots after
/// ten. Until then a person alone in the pool can take bots at once, or
/// wait up to five minutes for another person; one waiting for a person
/// can still take bots whenever they like.
class _WaitingView extends StatelessWidget {
  const _WaitingView({required this.queue, required this.onCancel, required this.onWaitForPerson, required this.onPlayWithBots});

  final WaitingRoom queue;
  final VoidCallback onCancel;
  final VoidCallback onWaitForPerson;
  final VoidCallback onPlayWithBots;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final waitedMs = DateTime.now().millisecondsSinceEpoch - queue.since;
    final waited = waitedMs ~/ 1000;
    final others = queue.present.length - 1 < 0 ? 0 : queue.present.length - 1;
    final patient = queue.botsAfterMs == WaitingRoom.personAtMostMs;
    final eager = queue.botsAfterMs == 0;
    // Offered while the pool is empty: with somebody else waiting, the
    // two are seated together at the pool's ten seconds.
    final choosing = !patient && !eager && others == 0 && waitedMs < queue.botsAfterMs;
    final line = patient
        ? l10n.waitingForPersonLine(_clock(waited), others)
        : eager
            ? null
            : l10n.waitedLine(waited, others);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.gameLine(queue.target, queue.pool),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Palette.chromeDim, letterSpacing: 0.4)),
        const SizedBox(height: 26),
        const Center(child: SizedBox(width: 30, height: 30, child: CircularProgressIndicator(color: Palette.gold, strokeWidth: 2.5))),
        const SizedBox(height: 22),
        Text(eager ? l10n.seatingWithBots : patient ? l10n.waitingForPerson : l10n.findingPlayers,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Palette.chrome)),
        if (line != null) ...[
          const SizedBox(height: 6),
          Text(line, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
        ],
        if (choosing) ...[
          const SizedBox(height: 22),
          FilledButton(onPressed: onPlayWithBots, style: _HomePageState._primary(), child: Text(l10n.playNowWithBots)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onWaitForPerson, style: _HomePageState._secondary(), child: Text(l10n.waitForPerson)),
          const SizedBox(height: 6),
          Text(l10n.waitForPersonHint, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Palette.chromeDim)),
        ],
        if (patient) ...[
          const SizedBox(height: 22),
          OutlinedButton(onPressed: onPlayWithBots, style: _HomePageState._secondary(), child: Text(l10n.playNowWithBots)),
        ],
        const SizedBox(height: 18),
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
  const RoomView({super.key, required this.room, required this.ledger, this.pictures, required this.onLeave, required this.onShare});

  final Room room;

  /// Ratings for the people here, from the results everyone signs;
  /// null until this device has read them off the relays.
  final Ledger? ledger;

  /// What this device does with the others' pictures, and who it
  /// blocked (pictures.dart).
  final Pictures? pictures;

  final VoidCallback onLeave;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final seconds = room.secondsToStart;
    final members = room.members;
    final pictures = this.pictures;
    // A member is shown as this device would show them at the table: a
    // blocked one by no name and no picture, a picture this device
    // keeps off by its icon.
    String idOf(RoomMember m) => m.licence?.account ?? m.key;
    bool blocked(RoomMember m) => m.key != room.me && (pictures?.isBlocked(idOf(m)) ?? false);
    Avatar avatarOf(RoomMember m) {
      final picture = m.avatar.picture;
      if (m.key == room.me || picture == null || pictures == null || pictures.allows(idOf(m))) return m.avatar;
      return m.avatar.copyWith(clearPicture: true);
    }

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
                    ? PlayerIcon(name: blocked(members[i]) ? l10n.blockedPlayer : members[i].name, seed: idOf(members[i]), avatar: avatarOf(members[i]), size: 30)
                    : const SizedBox(width: 30, height: 30, child: Icon(Icons.smart_toy_outlined, size: 20, color: Palette.chromeDim)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    i < members.length
                        ? (members[i].key == room.me ? l10n.nameIsYou(members[i].name) : blocked(members[i]) ? l10n.blockedPlayer : members[i].name)
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
                // A rating is the account's, whichever device it is in.
                if (i < members.length && ledger != null) _Rated(rating: ledger!.of(members[i].licence?.account ?? members[i].key)),
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

/// [seconds] as a clock says them: minutes, then seconds of two digits.
String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
