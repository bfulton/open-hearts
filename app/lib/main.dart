import 'package:flutter/material.dart';

import 'table_page.dart';
import 'theme.dart';

void main() => runApp(const OpenHeartsApp());

class OpenHeartsApp extends StatelessWidget {
  const OpenHeartsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open Hearts',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const TablePage(),
    );
  }
}
