/// What live play costs, what the money is for, and which of your
/// devices it is open on (docs/06-service.md).
///
/// Everything else is free and stays free — the bots, the records, the
/// verifiable deal, the engine itself. What is paid for is the part
/// that costs us money to run: relaying people to each other, a TURN
/// server when a direct path will not form, and a juror when a table
/// is left alone. That is worth saying on the page rather than leaving
/// a price on a padlock.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart' show SignInWithAppleButton, SignInWithAppleButtonStyle;
import 'package:url_launcher/url_launcher.dart';
import 'package:table/table.dart';

import 'activate_page.dart';
import 'entitlement.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/copy.dart';
import 'net/buying.dart';
import 'net/household.dart';
import 'net/provider_tokens.dart';
import 'net/remote_config.dart';
import 'net/share.dart';
import 'net/sign_in.dart';
import 'net/store_buying.dart';
import 'pages.dart';
import 'theme.dart';
import 'ui/qr_view.dart';
import 'ui/reading_time.dart';

Future<void> showSubscribe(BuildContext context) =>
    openPage<void>(context, AppPage.subscription);

class SubscribePage extends StatefulWidget {
  const SubscribePage({super.key});

  @override
  State<SubscribePage> createState() => _SubscribePageState();
}

class _SubscribePageState extends State<SubscribePage> {
  bool _leaving = false;
  String? _refusal;

  Signer? _me;
  Household? _household;

  /// Why there is no list of devices, once the service has been asked
  /// for one and has not given it: said where the list would be,
  /// rather than leaving the "…" of a list still coming there for good.
  String? _unlisted;
  bool _listing = false;
  Ticket? _code;
  bool _working = false;

  /// The backup codes, once asked for: not on the screen until then.
  BackupCodes? _backups;

  /// The provider this device signed in with, once it has.
  Provider? _signedIn;

  /// A sign-in the service turned away because the account is on
  /// another device, kept while the page asks whether to move it here.
  ({Provider provider, String token})? _elsewhere;

  @override
  void initState() {
    super.initState();
    Entitlement.current.addListener(_changed);
    StoreShop.current.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    Entitlement.current.removeListener(_changed);
    StoreShop.current.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // Bought on this page, in a store: the page turns into the one a
    // subscriber sees, and that one lists the devices.
    final me = _me;
    if (me != null && Entitlement.current.live && _household == null && _unlisted == null && !_listing) {
      unawaited(_list(me));
    }
  }

  Future<void> _load() async {
    final me = await Identity.signer();
    final signedIn = await signedInWith();
    if (!mounted) return;
    setState(() {
      _me = me;
      _signedIn = signedIn;
    });
    final offered = providerTokens.offered;
    if (signedIn == null && offered.isNotEmpty) providerTokens.prepare(offered);
    if (!Entitlement.current.live) return;
    await _list(me);
  }

  /// Which listing is the latest: one that comes back after a newer one
  /// was asked for, or after a sign-in, says nothing about now.
  int _asked = 0;

  Future<void> _list(Signer me) async {
    final asked = ++_asked;
    _listing = true;
    final said = await devicesOn(me);
    _listing = false;
    if (asked != _asked) return;
    final household = said.answer;
    // The account's sign-in as the service has it, over the device's note.
    final signedIn = household != null && household.toldSignIn ? await noteSignIn(household.signIn) : _signedIn;
    if (!mounted) return;
    setState(() {
      _household = household;
      _unlisted = said.refusal?.say(context.l10n);
      _signedIn = signedIn;
    });
  }

  Future<void> _buy() async {
    setState(() {
      _leaving = true;
      _refusal = null;
    });
    final refusal = await buy(await Identity.signer());
    if (!mounted) return;
    // No refusal means the browser is on its way to the checkout, and
    // this page is about to stop existing: the spinner stays.
    if (refusal != null) {
      setState(() {
        _leaving = false;
        _refusal = refusal.say(context.l10n);
      });
    }
  }

  /// The store's own sheet. What comes of it arrives through the shop:
  /// a licence, which turns this page into a subscriber's, or a reason.
  Future<void> _buyInStore() async {
    setState(() => _refusal = null);
    await StoreShop.current.buy();
  }

  Future<void> _restore() async {
    setState(() => _refusal = null);
    await StoreShop.current.restore();
  }

  /// To Stripe's billing portal, for a web subscription: cancelling is
  /// the subscriber's to do, not a phone call's.
  Future<void> _manage() async {
    setState(() {
      _leaving = true;
      _refusal = null;
    });
    final refusal = await manageSubscription(await Identity.signer());
    if (!mounted) return;
    if (refusal != null) {
      setState(() {
        _leaving = false;
        _refusal = refusal.say(context.l10n);
      });
    }
  }

  Future<void> _showACode() async {
    final me = _me;
    if (me == null || _working) return;
    setState(() {
      _working = true;
      _refusal = null;
    });
    final said = await askForCode(me);
    if (!mounted) return;
    setState(() {
      _working = false;
      _code = said.answer;
      _refusal = said.refusal?.say(context.l10n);
    });
  }

  Future<void> _showBackups() async {
    final me = _me;
    if (me == null || _working) return;
    setState(() {
      _working = true;
      _refusal = null;
    });
    final said = await backupCodes(me);
    if (!mounted) return;
    setState(() {
      _working = false;
      _backups = said.answer ?? _backups;
      _refusal = said.refusal?.say(context.l10n);
    });
  }

  Future<void> _replaceBackups() async {
    final me = _me;
    if (me == null || _working) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(dialog.l10n.replaceCodesTitle),
        content: Text(dialog.l10n.replaceCodesBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(dialog.l10n.notNow)),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(dialog.l10n.replace)),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _working = true;
      _refusal = null;
    });
    final said = await backupCodes(me, replace: true);
    if (!mounted) return;
    setState(() {
      _working = false;
      _backups = said.answer ?? _backups;
      _refusal = said.refusal?.say(context.l10n);
    });
    if (said.answer != null) _say(context.l10n.codesMade);
  }

  Future<void> _emailBackups() async {
    final me = _me;
    if (me == null || _working) return;
    setState(() {
      _working = true;
      _refusal = null;
    });
    final said = await backupCodes(me, send: true);
    if (!mounted) return;
    setState(() {
      _working = false;
      _backups = said.answer ?? _backups;
      _refusal = said.refusal?.say(context.l10n);
    });
    if (said.answer case final sent?) {
      final l10n = context.l10n;
      _say(sent.emailed ? l10n.codesSent : (sent.unsent == 'no address' ? l10n.codesNoAddress : l10n.codesNotSent));
    }
  }

  /// A provider has answered. On a subscribed device the sign-in is
  /// linked to its account, so the account can be got back by it; on one
  /// that is not, this device comes into the account the sign-in is
  /// linked to, as a backup code would bring it.
  Future<void> _signInWith(Provider provider, Asked asked) async {
    final me = _me;
    final token = asked.token;
    if (me == null || _working) return;
    if (token == null) {
      if (asked.failed) setState(() => _refusal = context.l10n.signInFailed);
      return;
    }
    setState(() {
      _working = true;
      _refusal = null;
      _elsewhere = null;
    });
    final service = Entitlement.current.service;
    Said<SignedIn> said;
    if (Entitlement.current.live) {
      said = await attestWith(me, provider, token, service: service);
      if (said.refusal?.reason == 'accountElsewhere') {
        if (!mounted) return;
        setState(() {
          _working = false;
          _elsewhere = (provider: provider, token: token);
        });
        return;
      }
    } else {
      said = await supersedeWith(me, provider, token, service: service);
      if (said.refusal?.reason == 'accountNowhere') {
        // Nothing is linked to it yet: a sign-in is linked from a
        // subscriber's page, once there is an account to link it to.
        if (!mounted) return;
        setState(() => _working = false);
        _say(context.l10n.signedInNoSubscription);
        return;
      }
    }
    await _signedInAs(said);
  }

  /// This device into the account the sign-in is linked to, out of the
  /// one it is in: refused while that one is still paid for (the
  /// service sees to that).
  Future<void> _moveHere() async {
    final me = _me;
    final elsewhere = _elsewhere;
    if (me == null || elsewhere == null || _working) return;
    setState(() {
      _working = true;
      _refusal = null;
    });
    await _signedInAs(await supersedeWith(me, elsewhere.provider, elsewhere.token, service: Entitlement.current.service));
  }

  Future<void> _signedInAs(Said<SignedIn> said) async {
    if (!mounted) return;
    final done = said.answer;
    if (done == null) {
      setState(() {
        _working = false;
        _refusal = said.refusal?.say(context.l10n);
      });
      return;
    }
    await rememberSignIn(done.provider);
    _asked++;
    final wasLive = Entitlement.current.live;
    if (done.licence case final licence?) await Entitlement.current.adopt(licence);
    if (!mounted) return;
    final l10n = context.l10n;
    setState(() {
      _working = false;
      _signedIn = done.provider;
      _elsewhere = null;
    });
    _say(Entitlement.current.live ? (wasLive ? l10n.signedIn : l10n.activated) : l10n.signedInNoSubscription);
    // The household this device is on may be another one now.
    if (wasLive && Entitlement.current.live && _me != null) unawaited(_list(_me!));
  }

  Future<void> _copy(String text) async {
    await copyText(text);
    if (mounted) _say(context.l10n.copied);
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text, textAlign: TextAlign.center), duration: readingTime(text)));

  Future<void> _drop(PublicKey device) async {
    final me = _me;
    if (me == null || _working) return;
    setState(() {
      _working = true;
      _refusal = null;
    });
    final said = await devicesOn(me, drop: device);
    if (!mounted) return;
    setState(() {
      _working = false;
      _household = said.answer ?? _household;
      _refusal = said.refusal?.say(context.l10n);
    });
    // Dropped this very device: its licence is not renewed, and there
    // is no reason to go on holding one it can no longer replace.
    if (said.refusal == null && device == me.publicKey) {
      await Entitlement.current.forget();
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final licence = Entitlement.current.licence;
    final shop = StoreShop.current;
    // A store build buys in its store, and a store's purchase is still
    // being made while the sheet is up or the service is being shown it.
    final inStore = shop.ready;
    final waiting = _leaving || shop.busy;
    final refusal = _refusal ?? shop.refusal?.say(l10n);
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(l10n.subscription, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.subscription, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Palette.mark)),
                  const SizedBox(height: 6),
                  Text(
                    licence == null ? l10n.pricePerYear(priceShown) : l10n.openUntil(Licence.dayOf(licence.until)),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.chrome, letterSpacing: 0.2),
                  ),
                  const SizedBox(height: 22),
                  if (licence == null) ...[
                    _Point(icon: Icons.groups_outlined, text: l10n.seatsOrFriends),
                    _Point(icon: Icons.military_tech_outlined, text: l10n.pointRating),
                    _Point(icon: Icons.lock_outline, text: l10n.pointDeal),
                    const SizedBox(height: 18),
                    Text(
                      l10n.whatMoneyPaysFor,
                      style: const TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim),
                    ),
                    const SizedBox(height: 26),
                    FilledButton(
                      onPressed: waiting ? null : (inStore ? _buyInStore : _buy),
                      style: _gold(),
                      child: waiting
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Felt.dark))
                          : Text(l10n.subscribe, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 10),
                    if (inStore) ...[
                      // What the stores require beside the button: the
                      // price, the period, that it renews by itself, and
                      // how to stop it.
                      Text(
                        l10n.storeRenewal(priceShown, shop.store!.kind.name),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11.5, height: 1.45, color: Palette.chromeDim),
                      ),
                      if (shop.pending) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.storePending,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13, height: 1.4, color: Palette.chrome),
                        ),
                      ],
                      const SizedBox(height: 6),
                      // Apple requires a way back to a subscription this
                      // store account already has; a new phone needs one.
                      TextButton(
                        onPressed: waiting ? null : _restore,
                        child: Text(l10n.restorePurchases),
                      ),
                    ] else
                      Text(
                        canBuyHere ? l10n.cancelWhenever : l10n.storeSubscriptionLater,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim),
                      ),
                    const SizedBox(height: 6),
                    TextButton(onPressed: waiting ? null : () => showActivate(context), child: Text(l10n.haveACode)),
                    ..._account(subscribed: false, waiting: waiting),
                  ] else
                    ..._yours(),
                  const SizedBox(height: 14),
                  // What a subscription is bought under, a tap from where it
                  // is bought (a store's review asks for both).
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(onPressed: () => openLink(legalPage('privacy')), child: Text(l10n.privacyPolicy)),
                      TextButton(onPressed: () => openLink(legalPage('terms')), child: Text(l10n.termsOfUse)),
                    ],
                  ),
                  if (refusal != null) ...[
                    const SizedBox(height: 14),
                    Text(refusal, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A subscription is a person's, not a device's: so the page a
  /// subscriber sees is about which of their devices it is on.
  List<Widget> _yours() {
    final l10n = context.l10n;
    final house = _household;
    final code = _code;
    return [
      Text(
        l10n.subscriptionIsYours,
        style: const TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim),
      ),
      const SizedBox(height: 22),
      _Heading(l10n.yourDevices),
      const SizedBox(height: 8),
      if (house == null && _unlisted != null)
        Text(_unlisted!, style: const TextStyle(fontSize: 13, color: Palette.danger))
      else if (house == null)
        const Text('…', style: TextStyle(fontSize: 13, color: Palette.chromeDim))
      else ...[
        for (final device in house.devices)
          _DeviceLine(
            device: device,
            isThisOne: device.key == _me?.publicKey,
            onDrop: _working ? null : () => _drop(device.key),
          ),
        const SizedBox(height: 8),
        Text(l10n.devicesOf(house.devices.length, house.most),
            style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim)),
      ],
      const SizedBox(height: 20),
      if (code == null)
        FilledButton(
          onPressed: _working || (house?.full ?? false) ? null : _showACode,
          style: _gold(),
          child: _working
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Felt.dark))
              : Text(l10n.addDevice, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
        )
      else ...[
        Center(child: QrView(data: claimLink(code.code))),
        const SizedBox(height: 12),
        Text(
          l10n.pointTheCamera,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11.5, height: 1.45, color: Palette.chromeDim),
        ),
        const SizedBox(height: 14),
        Text(
          l10n.orTypeCode,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11.5, height: 1.45, color: Palette.chromeDim),
        ),
        const SizedBox(height: 6),
        _CodeLine(text: _grouped(code.code), onCopy: () => unawaited(_copy(code.code)), copy: l10n.copy),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => unawaited(_sendTheLink(code.code)),
          style: OutlinedButton.styleFrom(
            foregroundColor: Palette.gold,
            side: BorderSide(color: Palette.gold.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(l10n.sendLinkInstead),
        ),
      ],
      const SizedBox(height: 26),
      _Heading(l10n.backupCodes),
      const SizedBox(height: 8),
      Text(l10n.backupCodesHint, style: const TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim)),
      const SizedBox(height: 12),
      if (_backups case final backups?) ...[
        for (final c in backups.codes)
          _CodeLine(
            text: c.code,
            used: c.used ? l10n.codeUsedMark : null,
            onCopy: c.used ? null : () => unawaited(_copy(c.code)),
            copy: l10n.copy,
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: backups.unused.isEmpty ? null : () => unawaited(_copy(backups.unused.join('\n'))),
                style: _outlined(),
                child: Text(l10n.copy),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _working || backups.unused.isEmpty ? null : _emailBackups,
                style: _outlined(),
                child: Text(l10n.emailCodes),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _working ? null : _replaceBackups, style: _outlined(), child: Text(l10n.replaceCodes)),
      ] else
        OutlinedButton(onPressed: _working ? null : _showBackups, style: _outlined(), child: Text(l10n.showBackupCodes)),
      ..._account(subscribed: true, waiting: _leaving),
      // A web subscription is managed in Stripe's portal; one bought in
      // a store, in the store's own settings, which is the only place it
      // can be.
      if (StoreShop.current.store case final store? when StoreShop.current.boughtHere) ...[
        const SizedBox(height: 26),
        Text(l10n.manageInStore(store.kind.name), style: const TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim)),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => unawaited(openLink(store.kind.manage)),
          style: OutlinedButton.styleFrom(
            foregroundColor: Palette.gold,
            side: BorderSide(color: Palette.gold.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(l10n.manageSubscription),
        ),
      ] else if (canLeaveForStripe) ...[
        const SizedBox(height: 26),
        Text(l10n.manageSubscriptionHint, style: const TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim)),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _leaving ? null : _manage,
          style: OutlinedButton.styleFrom(
            foregroundColor: Palette.gold,
            side: BorderSide(color: Palette.gold.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(l10n.manageSubscription),
        ),
      ],
    ];
  }

  /// Signing in, where this build offers it: on a subscriber's page, so
  /// the subscription can be got back on a device that has lost it; on
  /// the page before buying, to get one back here. Nothing at all in a
  /// build that names no provider.
  List<Widget> _account({required bool subscribed, required bool waiting}) {
    final offered = providerTokens.offered;
    final me = _me;
    if (offered.isEmpty || me == null) return const [];
    final l10n = context.l10n;
    final signedIn = _signedIn;
    final elsewhere = _elsewhere;
    const hint = TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim);
    return [
      SizedBox(height: subscribed ? 26 : 18),
      if (subscribed) ...[_Heading(l10n.yourAccount), const SizedBox(height: 8)],
      if (signedIn != null)
        Text(subscribed ? l10n.signedInWith(signedIn.name) : l10n.signedInBeforeBuying(signedIn.name),
            textAlign: subscribed ? TextAlign.start : TextAlign.center, style: hint)
      else ...[
        Text(subscribed ? l10n.signInToKeep : l10n.signInToBringBack,
            textAlign: subscribed ? TextAlign.start : TextAlign.center, style: hint),
        const SizedBox(height: 12),
        for (final provider in offered) ...[
          _SignInButton(
            provider: provider,
            nonce: signInNonce(me.publicKey),
            label: l10n.signInWith(provider.name),
            enabled: !_working && !waiting,
            onAsked: (asked) => unawaited(_signInWith(provider, asked)),
          ),
          const SizedBox(height: 10),
        ],
      ],
      if (elsewhere != null) ...[
        const SizedBox(height: 4),
        Text(l10n.accountElsewhere, style: const TextStyle(fontSize: 13, height: 1.5, color: Palette.chrome)),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _working ? null : _moveHere, style: _outlined(), child: Text(l10n.moveAccountHere)),
      ],
    ];
  }

  /// The same link, for a device with no camera pointed at this one:
  /// the phone's share sheet where there is one, else the clipboard,
  /// and said so — as the room's link goes (home_page.dart).
  Future<void> _sendTheLink(String code) async {
    final link = claimLink(code);
    if (await shareLink(Uri.parse(link))) return;
    await copyText(link);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(context.l10n.linkCopied, textAlign: TextAlign.center), duration: const Duration(milliseconds: 1600), width: 200));
  }

  static ButtonStyle _outlined() => OutlinedButton.styleFrom(
        foregroundColor: Palette.gold,
        side: BorderSide(color: Palette.gold.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );

  /// A screen's code in fours, for a person to read across: the spaces
  /// are ignored where it is typed (net/household.dart, [codeIn]).
  static String _grouped(String code) => [for (var i = 0; i < code.length; i += 4) code.substring(i, i + 4 > code.length ? code.length : i + 4)].join(' ');

  static ButtonStyle _gold() => FilledButton.styleFrom(
        backgroundColor: Palette.gold,
        foregroundColor: Felt.dark,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
}

/// One provider's button: the provider's own where it insists on
/// drawing it (Google's, on the web), and otherwise one drawn here —
/// Apple's to Apple's own rules, Google's in the page's style.
class _SignInButton extends StatelessWidget {
  const _SignInButton({required this.provider, required this.nonce, required this.label, required this.enabled, required this.onAsked});

  final Provider provider;
  final String nonce;
  final String label;
  final bool enabled;
  final void Function(Asked asked) onAsked;

  Future<void> _ask() async => onAsked(await providerTokens.ask(provider, nonce));

  @override
  Widget build(BuildContext context) {
    final own = providerTokens.ownButton(provider, nonce, onAsked);
    if (own != null) return IgnorePointer(ignoring: !enabled, child: own);
    return switch (provider) {
      Provider.apple => SignInWithAppleButton(
          onPressed: enabled ? () => unawaited(_ask()) : null,
          text: label,
          style: SignInWithAppleButtonStyle.white,
          borderRadius: const BorderRadius.all(Radius.circular(22)),
        ),
      Provider.google => OutlinedButton.icon(
          onPressed: enabled ? () => unawaited(_ask()) : null,
          icon: const Icon(Icons.account_circle_outlined, size: 20),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Palette.chrome,
            minimumSize: const Size.fromHeight(44),
            side: BorderSide(color: Palette.chrome.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          ),
        ),
    };
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Palette.chromeDim, letterSpacing: 0.6),
      );
}

class _DeviceLine extends StatelessWidget {
  const _DeviceLine({required this.device, required this.isThisOne, this.onDrop});

  final Device device;
  final bool isThisOne;
  final VoidCallback? onDrop;

  @override
  Widget build(BuildContext context) {
    // The day under the name rather than beside it: a device has no
    // name here and is not asked for one, so what tells two of them
    // apart is six characters of key and the day it arrived — and
    // three things on one line is a line that overflows on a phone.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(isThisOne ? Icons.smartphone : Icons.devices_other, size: 17, color: Palette.chromeDim),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isThisOne ? context.l10n.thisDevice : device.shortened,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: isThisOne ? Palette.chrome : Palette.chromeDim,
                    fontWeight: isThisOne ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (device.boundAt != null || device.inUse)
                  Text(
                      [
                        if (device.boundAt != null) context.l10n.deviceSince(device.boundAt!),
                        // The account's device in use now: one at a time
                        // (net/in_use.dart).
                        if (device.inUse) context.l10n.deviceInUse,
                      ].join(' · '),
                      style: const TextStyle(fontSize: 11, color: Palette.chromeDim)),
              ],
            ),
          ),
          TextButton(
            onPressed: onDrop,
            style: TextButton.styleFrom(
              foregroundColor: Palette.danger,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(isThisOne ? context.l10n.dropThisOne : context.l10n.drop, style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Palette.chromeDim),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.4, color: Palette.chrome)),
          ),
        ],
      ),
    );
  }
}

/// The site's page [name] — `privacy` or `terms` — or where the remote
/// config says it is. On the web the site is the app's own host without
/// its `play.` (play.openhearts.game's site is openhearts.game), or the
/// app's own origin on a preview, which serves the app beside the site
/// at /play/; a phone's build has no origin and goes to the site's home.
Uri legalPage(String name, {Uri? base}) {
  final config = RemoteSettings.current.config;
  final set = name == 'privacy' ? config.privacy : config.terms;
  if (set != null) return set;
  final at = base ?? Uri.base;
  if ((at.scheme == 'https' || at.scheme == 'http') && at.host.isNotEmpty) {
    final host = at.host.startsWith('play.') ? at.host.substring('play.'.length) : at.host;
    return Uri(scheme: at.scheme, host: host, port: at.hasPort ? at.port : null, path: '/$name');
  }
  return Uri.parse('https://openhearts.game/$name');
}

/// Opens [url] in the browser or the phone's own, and says nothing when
/// it cannot: a link that does not open is a link tapped again.
Future<void> openLink(Uri url) async {
  try {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {}
}


/// A code on a line of its own, set to be read and copied.
class _CodeLine extends StatelessWidget {
  const _CodeLine({required this.text, required this.copy, this.onCopy, this.used});

  final String text;
  final String copy;
  final VoidCallback? onCopy;

  /// Said beside a code that has been used, which is crossed out.
  final String? used;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: used == null ? Palette.chrome : Palette.chromeDim,
                decoration: used == null ? null : TextDecoration.lineThrough,
              ),
            ),
          ),
          if (used != null) ...[
            const SizedBox(width: 8),
            Text(used!, style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim)),
          ] else
            IconButton(
              tooltip: copy,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18, color: Palette.chromeDim),
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }
}
