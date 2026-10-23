/// Live play open only where the phone's store lets it
/// (net/age_check.dart): asked as the player goes to a live table and
/// before they buy live play in the store, and where the store says no,
/// said why, with playing alone left open.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n/l10n.dart';
import 'net/age_check.dart';

/// Whether the store lets this player play live; where it does not,
/// they are told why before this answers.
Future<bool> storeLetsPlayLive(BuildContext context) async {
  final verdict = await askStoreAge();
  if (verdict == AgeVerdict.open) return true;
  if (!context.mounted) return false;
  await showDialog<void>(context: context, builder: (_) => AgeClosed(verdict: verdict));
  return false;
}

/// Why live play is closed to this player, by what their store said.
class AgeClosed extends StatelessWidget {
  const AgeClosed({super.key, required this.verdict});

  final AgeVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The age comes from the player's Apple Account, or from Google Play.
    final store = defaultTargetPlatform == TargetPlatform.android ? 'google' : 'apple';
    final (title, body) = switch (verdict) {
      AgeVerdict.tooYoung => (l10n.liveTooYoungTitle, l10n.liveTooYoung(store)),
      AgeVerdict.awaitingParent => (l10n.liveAwaitingParentTitle, l10n.liveAwaitingParent),
      AgeVerdict.parentDeclined => (l10n.liveParentDeclinedTitle, l10n.liveParentDeclined),
      AgeVerdict.unconfirmed => (l10n.liveAgeUnconfirmedTitle, l10n.liveAgeUnconfirmed),
      AgeVerdict.open => throw ArgumentError.value(verdict, 'verdict', 'live play is open'),
    };
    return AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
