/// Mints a signing pair (docs/explanation/service.md): the service's,
/// the house's, or the previews' of either.
///
///     dart run bin/service_key.dart
///
/// Says the pair as one line of JSON, {"key", "secret"}, for the command
/// that sets the secret itself and shows it to nobody: `oh key mint`,
/// `oh house key` and `oh preview secrets` (ops/preview.mjs).
///
/// The public half is what every build is compiled to expect
/// (OH_SERVICE_KEY, app/lib/net/licence.dart) and is not a secret. The
/// secret half signs licences and belongs in the project's secrets
/// (OH_SERVICE_SECRET) and nowhere else: not in the repository, not in a
/// build, not on a device, not in a file.
///
/// Rotating replaces the pair everywhere at once, since every part
/// checks against one key and the worker signs only with a matching
/// pair (docs/how-to/rotate-the-service-key.md).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;

void main() {
  final rng = Random.secure();
  final secret = List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final key = bip340.getPublicKey(secret);
  stdout.writeln(jsonEncode({'key': key, 'secret': secret}));
}
