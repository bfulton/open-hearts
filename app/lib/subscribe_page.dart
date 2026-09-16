/// What live play costs and what the money is for (docs/06-service.md).
///
/// Everything else is free and stays free — the bots, the records, the
/// verifiable deal, the engine itself. What is paid for is the part
/// that costs us money to run: relaying people to each other, a TURN
/// server when a direct path will not form, and a juror when a table
/// is left alone. That is worth saying on the page rather than leaving
/// a price on a padlock.
library;

import 'package:flutter/material.dart';

import 'entitlement.dart';
import 'identity.dart';
import 'net/buying.dart';
import 'net/licence.dart';
import 'theme.dart';

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
        _refusal = refusal;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final licence = Entitlement.current.licence;
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: const Text('Live play', style: TextStyle(fontSize: 16, color: Palette.chromeDim)),
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
                  const Text('Live play', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Palette.mark)),
                  const SizedBox(height: 6),
                  const Text(price,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.chrome, letterSpacing: 0.2)),
                  const SizedBox(height: 22),
                  const _Point(
                    icon: Icons.groups_outlined,
                    text: 'Four seats, filled with whoever is waiting — or a link you send to three friends.',
                  ),
                  const _Point(
                    icon: Icons.military_tech_outlined,
                    text: 'A rating of your own, from results the four of you sign.',
                  ),
                  const _Point(
                    icon: Icons.lock_outline,
                    text: 'The deal is dealt between the four of you. No server sees a hand, ours included.',
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Playing alone is free and always will be, and so are the records, '
                    'the engine and every line of this. What the money pays for is the part that '
                    'costs us to run: putting you in touch with each other, a relay when your two '
                    'devices cannot find a way through, and a juror when a table is left alone.',
                    style: TextStyle(fontSize: 13, height: 1.5, color: Palette.chromeDim),
                  ),
                  const SizedBox(height: 26),
                  if (licence != null) ...[
                    _Note(
                      icon: Icons.check_circle_outline,
                      text: 'Live play is open on this device, to ${Licence.dayOf(licence.until)}.',
                      colour: Palette.gold,
                    ),
                  ] else ...[
                    FilledButton(
                      onPressed: _leaving ? null : _buy,
                      style: FilledButton.styleFrom(
                        backgroundColor: Palette.gold,
                        foregroundColor: Felt.dark,
                        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _leaving
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Felt.dark))
                          : const Text('Subscribe', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      canBuyHere
                          ? 'Cancel whenever you like; the year you paid for runs out on its own.'
                          : 'On a phone this will be the store\'s own subscription. Until the app is in the stores, '
                              'live play is bought on the web.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim),
                    ),
                  ],
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

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, required this.colour});

  final IconData icon;
  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, color: colour, fontWeight: FontWeight.w600))),
      ],
    );
  }
}
