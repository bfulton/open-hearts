/// Mints the service's signing pair (docs/06-service.md).
///
///     dart run bin/service_key.dart
///
/// The public half is what every build is compiled to expect
/// (OH_SERVICE_KEY, app/lib/net/licence.dart) and is not a secret: it
/// is printed. The secret half signs licences and belongs in the
/// project's secrets (OH_SERVICE_SECRET) and nowhere else — not in the
/// repository, not in a build, not on a device — so it is written to a
/// file for one paste and then deleted by you.
///
/// Rotating is cheap and takes a month: publish a build naming the new
/// key, and keep signing with the old secret until the licences it
/// signed have run out.
library;

import 'dart:io';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;

void main(List<String> args) {
  final to = args.isEmpty ? 'service.secret' : args.first;
  final rng = Random.secure();
  final secret = List.generate(32, (_) => rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final file = File(to);
  file.writeAsStringSync(secret);
  stdout
    ..writeln('OH_SERVICE_KEY    ${bip340.getPublicKey(secret)}')
    ..writeln('OH_SERVICE_SECRET written to $to — paste it into the project\'s secrets, then delete the file');
}
