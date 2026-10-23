/// The name filter the app asks before a name leaves the device
/// (names.dart) answers as the service's and the relay's does
/// (service/functions/names.mjs): both are held to the cases in
/// service/functions/names.vectors.json. What it refuses, and why, is
/// proved there, in `node --test service/functions` (names.test.mjs).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/names.dart';

void main() {
  final vectors = jsonDecode(File('../service/functions/names.vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('refuses what the service refuses', () {
    final refused = (vectors['refused'] as List).cast<String>();
    expect(refused, isNotEmpty);
    expect([for (final n in refused) if (!nameRefused(n)) n], isEmpty);
  });

  test('lets be what the service lets be', () {
    final allowed = (vectors['allowed'] as List).cast<String>();
    expect(allowed, isNotEmpty);
    expect([for (final n in allowed) if (nameRefused(n)) n], isEmpty);
  });
}
