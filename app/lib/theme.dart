/// The look of the table.
///
/// One deliberate palette rather than a light/dark pair: a card game
/// wants to read as a table, not as a form, and the felt is the whole
/// reason the white of a card carries.
library;

import 'package:flutter/material.dart';

abstract final class Felt {
  static const dark = Color(0xFF06231A);
  static const mid = Color(0xFF0E3B2E);
  static const light = Color(0xFF14513C);

  /// The table itself: lighter under the trick, darker at the rails.
  static const gradient = RadialGradient(
    center: Alignment(0, -0.15),
    radius: 0.95,
    colors: [light, mid, dark],
    stops: [0.0, 0.55, 1.0],
  );
}

abstract final class Palette {
  static const gold = Color(0xFFE4B363);
  static const goldDim = Color(0x66E4B363);
  static const cardFace = Color(0xFFFAF7F0);
  static const cardEdge = Color(0xFF2A2E2B);
  static const red = Color(0xFFC1352B);
  static const black = Color(0xFF1B1B1F);
  static const chrome = Color(0xFFE8EFEA);
  static const chromeDim = Color(0x99E8EFEA);
  static const danger = Color(0xFFE0674F);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Felt.dark,
    colorScheme: base.colorScheme.copyWith(
      primary: Palette.gold,
      surface: Felt.mid,
      onSurface: Palette.chrome,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Palette.chrome,
      displayColor: Palette.chrome,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xF0102A22),
      contentTextStyle: TextStyle(color: Palette.chrome),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
