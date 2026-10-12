/// Mints the service's signing pair (docs/explanation/service.md).
///
///     dart run bin/service_key.dart
///
/// The public half is what every build is compiled to expect
/// (OH_SERVICE_KEY, app/lib/net/licence.dart) and is not a secret: it
/// is printed. The secret half signs licences and belongs in the
/// project's secrets (OH_SERVICE_SECRET) and nowhere else — not in the
/// repository, not in a build, not on a device, not in a file — so it
/// is printed once, here, to be pasted there.
///
/// Rotating replaces the pair everywhere at once, since every part
/// checks against one key and the worker signs only with a matching
/// pair (docs/how-to/rotate-the-service-key.md).
library;

import 'dart:io';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;

void main() {
  final rng = Random.secure();
  final secret = List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  stdout
    ..writeln('OH_SERVICE_KEY     ${bip340.getPublicKey(secret)}')
    ..writeln('OH_SERVICE_SECRET  $secret')
    ..writeln()
    ..writeln('The key goes in config/openhearts.json (serviceKey). The secret goes in the')
    ..writeln('project\'s secrets as OH_SERVICE_SECRET, and nowhere else: it is not kept here.');
}
