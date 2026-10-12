/// The verifiable deal's cryptography (docs/explanation/fair-deal.md), loaded
/// once at startup: the wasm next to the app on the web, the cdylib
/// over FFI elsewhere. Null when it could not be loaded, in which case
/// this device plays no live table at all — every live table is
/// sealed — and says so at the door (live/lobby.dart, net/room.dart).
///
/// With it, the worker that makes the deal's slow calls, so that a
/// shuffle or its check does not hold the screen still while it is made:
/// a Web Worker running `deal_worker.js` on the web, an isolate elsewhere
/// (packages/deal, work.dart). The deal has loaded when both have: a
/// worker that does not start is a deal that did not load, and nothing
/// slow is ever made on the screen's thread instead.
library;

import 'dart:async';

import 'package:deal/deal.dart';
import 'package:flutter/foundation.dart';

DealCrypto? dealCrypto;
DealWorker? dealWorker;

/// Whether this device can deal now: the deal loaded, and its worker
/// not failed for good since (packages/deal, ResilientDealWorker).
bool get dealReady => dealCrypto != null && !(dealWorker?.dead ?? true);

Future<void> loadDeal() async {
  try {
    // Together: the page's copy and the worker's load side by side.
    final (crypto, worker) = await (DealCrypto.load(), DealWorker.start()).wait;
    dealCrypto = crypto;
    dealWorker = worker;
  } on ParallelWaitError<(DealCrypto?, DealWorker?), (AsyncError?, AsyncError?)> catch (e) {
    e.values.$2?.close();
    debugPrint('deal: not loaded (${e.errors.$1?.error ?? e.errors.$2?.error}); this device plays no live table');
  }
}
