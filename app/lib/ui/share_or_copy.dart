/// A link sent from the app (a room's, or one to add a device): the
/// phone's share sheet where there is one, else onto the clipboard, and
/// said so.
library;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../net/copy.dart';
import '../net/share.dart';

Future<void> shareOrCopy(BuildContext context, Uri link) async {
  if (await shareLink(link)) return;
  await copyText(link.toString());
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(context.l10n.linkCopied, textAlign: TextAlign.center), duration: const Duration(milliseconds: 1600), width: 200));
}
