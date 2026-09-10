/// Native and VM: the Dart implementation is fast enough.
library;

import 'package:table/table.dart';

/// Nothing to install.
Future<void> installFastSchnorr() async {}

Signer signerFromSecret(String secretHex) => SchnorrSigner.fromSecret(secretHex);
