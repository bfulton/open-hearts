/// Native and VM: the cdylib when it is built and can be found — a
/// desktop run from the repository — else the Dart implementation,
/// which is fast enough for one player's own traffic.
library;

import 'package:table/table.dart';

Future<void> installFastSchnorr() async {
  await installNativeSchnorr();
}

Signer signerFromSecret(String secretHex) => SchnorrSigner.fromSecret(secretHex);
