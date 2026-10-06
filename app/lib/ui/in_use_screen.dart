/// What a device that has stepped back for another device of its account
/// shows, over whatever was on the screen (net/in_use.dart,
/// docs/06-service.md): that Open Hearts is open on another device, and
/// the way to take it back. And before taking the account from a game
/// on another device, the question: continue here, and lose that game?
///
/// Over everything, because the device has left everything live: the
/// table it sat at, the pool, the jury, a game it was watching. Solo play
/// needs no account, so "Not now" puts the screen aside and leaves the
/// rest of the app as it was; the front door then says live play is open
/// on the other device.
library;

import 'package:flutter/material.dart';

import '../identity.dart';
import '../l10n/l10n.dart';
import '../net/in_use.dart';
import '../theme.dart';
import 'folding_heart.dart';

class InUseScreen extends StatelessWidget {
  const InUseScreen({super.key, required this.child, this.inUse});

  final Widget child;

  /// The account's standing on this device: [InUse.current] unless a
  /// test says otherwise.
  final InUse? inUse;

  @override
  Widget build(BuildContext context) {
    final use = inUse ?? InUse.current;
    return ListenableBuilder(
      listenable: use,
      builder: (context, _) {
        final standing = use.standing;
        final shown = (standing == Use.elsewhere && !use.dismissed) || standing == Use.playingElsewhere;
        return Stack(
          children: [
            child,
            // Over everything, and what is under it is not read out:
            // nothing there is live any more.
            if (shown) Positioned.fill(child: BlockSemantics(child: _Notice(use: use, playing: standing == Use.playingElsewhere))),
          ],
        );
      },
    );
  }
}

class _Notice extends StatefulWidget {
  const _Notice({required this.use, required this.playing});

  final InUse use;

  /// The account is at a table on the other device: taking it loses
  /// that game, and the person is asked.
  final bool playing;

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  bool _busy = false;

  /// Takes the account here: asked first if the other device is at a
  /// table; on the person's word, whatever it is doing.
  Future<void> _useHere({required bool take}) async {
    setState(() => _busy = true);
    await widget.use.open(await Identity.signer(), take: take);
    if (mounted) setState(() => _busy = false);
  }

  void _notNow() => widget.use.putAside();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playing = widget.playing;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: FoldingHeart(size: 46, color: Palette.mark)),
                    const SizedBox(height: 22),
                    Semantics(
                      header: true,
                      child: Text(
                        playing ? l10n.inGameElsewhereTitle : l10n.openElsewhereTitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: Palette.chrome, height: 1.25),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      playing ? l10n.inGameElsewhereBody : l10n.openElsewhereBody,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, height: 1.5, color: Palette.chromeDim),
                    ),
                    const SizedBox(height: 26),
                    FilledButton(
                      onPressed: _busy ? null : () => _useHere(take: playing),
                      style: FilledButton.styleFrom(
                        backgroundColor: Palette.gold,
                        foregroundColor: Felt.dark,
                        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Felt.dark))
                          : Text(playing ? l10n.continueHere : l10n.useItHere,
                              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy ? null : _notNow,
                      style: TextButton.styleFrom(foregroundColor: Palette.chromeDim),
                      child: Text(l10n.notNow),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
