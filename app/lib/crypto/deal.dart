/// The verifiable deal's cryptography (docs/03-fair-deal.md), loaded
/// once at startup: the wasm next to the app on the web, the cdylib
/// over FFI elsewhere. Null when it could not be loaded, in which case
/// this device plays no live table at all — every live table is
/// sealed — and says so at the door (home_page.dart, net/room.dart).
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
