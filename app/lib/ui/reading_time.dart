/// How long a passing message stays up: long enough to read. "Copied."
/// needs a glance; a sentence saying why something did not happen needs
/// reading, and one cut off halfway is worse than none.
library;

import 'package:flutter/material.dart';

Duration readingTime(String text) =>
    Duration(milliseconds: (1500 + text.length * 50).clamp(1800, 6000));

/// Says [message] at the foot of a table's screen for as long as it
/// takes to read, in place of whatever was said there before.
void sayBriefly(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message, textAlign: TextAlign.center),
      duration: readingTime(message),
      width: 260,
    ));
}
