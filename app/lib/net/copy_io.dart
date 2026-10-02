import 'package:flutter/services.dart';

Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));
