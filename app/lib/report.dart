/// Reporting another player to the people who run Open Hearts.
///
/// What about them — their picture, their name, or something else —
/// and a few words if the player wants, sent at once by email to the
/// operator (service/functions/alerts.mjs, alertReport), with both
/// accounts' numbers, the table, and the name and picture as this
/// device shows them: what the operator needs to judge it, and nothing
/// to the player reported. A device has to be a subscriber's to send
/// one, as it has to be to play live.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:table/table.dart' show sha256Hex;

import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/household.dart';
import 'theme.dart';

enum ReportWhat { picture, name, other }

class Report {
  const Report({required this.about, required this.what, this.table, this.name, this.picture, this.note = ''});

  /// The player reported: their account, or their device's key where
  /// no account names one.
  final String about;
  final ReportWhat what;

  /// The table it happened at.
  final String? table;

  /// Their name and the SHA-256 of their picture, as this device showed
  /// them: what the operator compares with the account's profile now.
  final String? name;
  final String? picture;
  final String note;

  Map<String, Object?> toJson() => {
        'about': about,
        'what': what.name,
        if (table != null) 'table': table,
        if (name != null) 'name': name,
        if (picture != null) 'picture': picture,
        if (note.isNotEmpty) 'note': note,
      };
}

/// The most a note may be, in characters (REPORT_NOTE_MOST,
/// service/functions/alerts.mjs).
const reportNoteMost = 500;

/// How a report went.
enum ReportSent { sent, tooMany, failed }

typedef ReportSender = Future<ReportSent> Function(Report report);

/// Sends [report], signed by this device.
Future<ReportSent> sendReport(Report report) async {
  final answer = await askHandler('report', await Identity.signer(), report.toJson(), null, what: '${report.about} ${report.what.name}');
  return switch (answer?.status) {
    200 => ReportSent.sent,
    429 => ReportSent.tooMany,
    _ => ReportSent.failed,
  };
}

/// The SHA-256 of a picture's bytes, in hex: how the service names it.
String pictureDigest(Uint8List jpeg) => sha256Hex(jpeg);

/// Asks what is wrong with [name]'s account [about], and sends it with
/// [send]; says how it went. [picture] is theirs as this device shows
/// it, if any: only then can it be what is reported. [shown] is what
/// the sheet calls them, where that is not their name: a player this
/// device blocked.
Future<void> showReport(BuildContext context,
    {required String about, required String name, String? shown, Uint8List? picture, String? table, ReportSender send = sendReport}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final report = await showModalBottomSheet<Report>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Felt.mid,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheet) => _ReportSheet(about: about, name: name, shown: shown ?? name, picture: picture, table: table),
  );
  if (report == null) return;
  final sent = await send(report);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(
        switch (sent) {
          ReportSent.sent => l10n.reportSent,
          ReportSent.tooMany => l10n.reportTooMany,
          ReportSent.failed => l10n.reportFailed,
        },
        textAlign: TextAlign.center,
      ),
      width: 300,
    ));
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.about, required this.name, required this.shown, required this.picture, required this.table});

  final String about;
  final String name;
  final String shown;
  final Uint8List? picture;
  final String? table;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportWhat? _what;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _send() {
    final picture = widget.picture;
    Navigator.of(context).pop(Report(
      about: widget.about,
      what: _what!,
      table: widget.table,
      name: widget.name,
      picture: picture == null ? null : pictureDigest(picture),
      note: _note.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final choices = [
      if (widget.picture != null) (ReportWhat.picture, l10n.reportTheirPicture),
      (ReportWhat.name, l10n.reportTheirName),
      (ReportWhat.other, l10n.reportSomethingElse),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.reportPlayer(widget.shown), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(l10n.reportWhat, style: const TextStyle(fontSize: 13, color: Palette.chromeDim)),
              RadioGroup<ReportWhat>(
                groupValue: _what,
                onChanged: (what) => setState(() => _what = what),
                child: Column(
                  children: [
                    for (final (what, label) in choices)
                      RadioListTile<ReportWhat>(value: what, title: Text(label), dense: true, contentPadding: EdgeInsets.zero),
                  ],
                ),
              ),
              TextField(
                controller: _note,
                maxLength: reportNoteMost,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(hintText: l10n.reportNoteHint),
              ),
              Text(l10n.reportGoesTo, style: const TextStyle(fontSize: 12, color: Palette.chromeDim)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _what == null ? null : _send, child: Text(l10n.reportSend)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
