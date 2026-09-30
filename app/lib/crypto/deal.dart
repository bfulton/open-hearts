/// The verifiable deal's cryptography (docs/03-fair-deal.md), loaded
/// once at startup: the wasm next to the app on the web, the cdylib
/// over FFI elsewhere. Null when it could not be loaded, in which case
/// this device plays no live table at all — every live table is
/// sealed — and says so at the door (home_page.dart, net/room.dart).
///
/// With it, a worker for the deal's slow calls, so that a shuffle or
/// its check does not hold the screen still while it is made: a Web
/// Worker running `deal_worker.js` on the web, an isolate elsewhere
/// (packages/deal, work.dart). A worker that fails hands its work
/// back, and the table makes it here as it always could.
library;

import 'package:deal/deal.dart';
import 'package:flutter/foundation.dart';

DealCrypto? dealCrypto;
DealWorker? dealWorker;

Future<void> loadDeal() async {
  try {
    dealCrypto = await DealCrypto.load();
    dealWorker = DealWorker.start();
  } catch (e) {
    debugPrint('deal: not loaded ($e); live tables will not be sealed');
  }
}
