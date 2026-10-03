/// Bringing this device onto a subscription already bought
/// (docs/06-service.md): with the code another of the subscriber's
/// devices shows, scanned or typed, or with a backup code from the
/// email. Here the person has come for it, so unlike a link that
/// arrives from anywhere (home_page.dart), there is nothing to ask
/// first: the code is the answer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'entitlement.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/household.dart';
import 'pages.dart';
import 'theme.dart';
import 'ui/scan_setup_io.dart' if (dart.library.js_interop) 'ui/scan_setup_web.dart' as scanner;

Future<void> showActivate(BuildContext context) =>
    openPage<void>(context, AppPage.activate);

class ActivatePage extends StatefulWidget {
  const ActivatePage({super.key});

  @override
  State<ActivatePage> createState() => _ActivatePageState();
}

class _ActivatePageState extends State<ActivatePage> {
  final _field = TextEditingController();
  bool _working = false;
  String? _refusal;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _field.text = text;
      _refusal = null;
    });
  }

  Future<void> _scan() async {
    setState(() => _refusal = null);
    final read = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (read == null || !mounted) return;
    _field.text = read;
    await _activate();
  }

  Future<void> _activate() async {
    final code = codeIn(_field.text);
    if (code == null) {
      setState(() => _refusal = context.l10n.serviceRefusal('notACode'));
      return;
    }
    setState(() {
      _working = true;
      _refusal = null;
    });
    final said = await claimCode(await Identity.signer(), code, service: Entitlement.current.service);
    if (!mounted) return;
    if (said.answer != null) {
      await Entitlement.current.adopt(said.answer!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.activated, textAlign: TextAlign.center)));
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _working = false;
      _refusal = said.refusal!.say(context.l10n);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Felt.dark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(l10n.activateSubscription, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
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
                  Text(l10n.activateBody, style: const TextStyle(fontSize: 13.5, height: 1.5, color: Palette.chromeDim)),
                  const SizedBox(height: 22),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(l10n.scanCode),
                    style: _outlined(),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _field,
                    enabled: !_working,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(color: Palette.chrome, fontSize: 15, letterSpacing: 0.8),
                    onSubmitted: (_) => unawaited(_activate()),
                    onChanged: (_) {
                      if (_refusal != null) setState(() => _refusal = null);
                    },
                    decoration: InputDecoration(
                      labelText: l10n.code,
                      hintText: 'XXXX-XXXX-XXXX-XXXX',
                      suffixIcon: IconButton(
                        tooltip: l10n.paste,
                        icon: const Icon(Icons.content_paste),
                        onPressed: _working ? null : _paste,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _working ? null : _activate,
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.gold,
                      foregroundColor: Felt.dark,
                      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _working
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Felt.dark))
                        : Text(l10n.activate, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
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

  static ButtonStyle _outlined() => OutlinedButton.styleFrom(
        foregroundColor: Palette.gold,
        side: BorderSide(color: Palette.gold.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      );
}

/// The camera, until it reads a code this app takes: popped with the
/// text it read. A QR of anything else is passed over.
class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  MobileScannerController? _camera;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    await scanner.prepareScanner();
    if (!mounted) return;
    setState(() => _camera = MobileScannerController(formats: const [BarcodeFormat.qrCode]));
  }

  @override
  void dispose() {
    unawaited(_camera?.dispose());
    super.dispose();
  }

  void _read(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && codeIn(raw) != null) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final camera = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Palette.chromeDim,
        title: Text(l10n.scanCode, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
      ),
      body: Column(
        children: [
          Expanded(
            child: camera == null
                ? const Center(child: CircularProgressIndicator())
                : MobileScanner(
                    controller: camera,
                    onDetect: _read,
                    errorBuilder: (context, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(l10n.noCamera,
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Palette.chrome)),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
            child: Text(l10n.pointAtCode,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: Palette.chromeDim)),
          ),
        ],
      ),
    );
  }
}
