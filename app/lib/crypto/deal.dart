/// The verifiable deal's cryptography (docs/03-fair-deal.md), loaded
/// once at startup: the wasm next to the app on the web, the cdylib
/// over FFI elsewhere. Null when it could not be loaded, in which case
/// this device deals no sealed table and sits at none.
library;

import 'package:deal/deal.dart';
import 'package:flutter/foundation.dart';

DealCrypto? dealCrypto;

Future<void> loadDeal() async {
  try {
    dealCrypto = await DealCrypto.load();
  } catch (e) {
    debugPrint('deal: not loaded ($e); live tables will not be sealed');
  }
}
