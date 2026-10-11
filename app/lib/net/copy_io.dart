import 'package:flutter/services.dart';

Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));

Future<String?> pasteText() async {
  try {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {
    return null;
  }
}
