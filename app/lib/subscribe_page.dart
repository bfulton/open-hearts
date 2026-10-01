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
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:table/table.dart';

import 'entitlement.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/buying.dart';
import 'net/household.dart';
import 'net/licence.dart';
import 'net/remote_config.dart';
import 'net/share.dart';
import 'theme.dart';
import 'ui/qr_view.dart';

Future<void> showSubscribe(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SubscribePage()));

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
  Ticket? _code;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    Entitlement.current.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    Entitlement.current.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final me = await Identity.signer();
    if (!mounted) return;
    setState(() => _me = me);
    if (!Entitlement.current.live) return;
    final said = await devicesOn(me);
    if (!mounted) return;
    setState(() {
      _household = said.answer;
      _unlisted = said.refusal?.say(context.l10n);
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
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(l10n.livePlay, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
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
                  Text(l10n.livePlay, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Palette.mark)),
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
                      onPressed: _leaving ? null : _buy,
                      style: _gold(),
                      child: _leaving
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Felt.dark))
                          : Text(l10n.subscribe, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      canBuyHere ? l10n.cancelWhenever : l10n.storeSubscriptionLater,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim),
                    ),
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
                  if (_refusal != null) ...[
                    const SizedBox(height: 14),
                    Text(_refusal!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger, fontSize: 13)),
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
    ];
  }

  /// The same link, for a device with no camera pointed at this one:
  /// the phone's share sheet where there is one, else the clipboard,
  /// and said so — as the room's link goes (home_page.dart).
  Future<void> _sendTheLink(String code) async {
    final link = claimLink(code);
    if (await shareLink(Uri.parse(link))) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(context.l10n.linkCopied, textAlign: TextAlign.center), duration: const Duration(milliseconds: 1600), width: 200));
  }

  static ButtonStyle _gold() => FilledButton.styleFrom(
        backgroundColor: Palette.gold,
        foregroundColor: Felt.dark,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
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
                if (device.boundAt != null)
                  Text(context.l10n.deviceSince(device.boundAt!), style: const TextStyle(fontSize: 11, color: Palette.chromeDim)),
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
/// config says it is. The site is the app's own origin on the web, the
/// app being served beside it at /play; a phone's build has no origin
/// and goes to the site's home.
Uri legalPage(String name, {Uri? base}) {
  final config = RemoteSettings.current.config;
  final set = name == 'privacy' ? config.privacy : config.terms;
  if (set != null) return set;
  final at = base ?? Uri.base;
  if ((at.scheme == 'https' || at.scheme == 'http') && at.host.isNotEmpty) {
    return Uri(scheme: at.scheme, host: at.host, port: at.hasPort ? at.port : null, path: '/$name');
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

