/// Finished games, kept to be looked at afterwards (router.dart,
/// `/table/ID`; service/functions/records.mjs).
///
/// A player's device sends its record when the game is over; the first
/// copy is the one kept, so a table's other players sending theirs costs
/// nothing. Whoever opens a game fetches it by the table's id and checks
/// it themselves before showing a card of it (review_page.dart).
///
/// Looking at a game is live play, which is a subscription's: the
/// service shows a record only to an account's device in use, and not
/// of a game its account is at (service/functions/worker.mjs, review).
library;

import 'dart:convert';

import 'package:table/table.dart';

import '../entitlement.dart';
import '../identity.dart';
import 'household.dart' show askHandler;
import 'in_use.dart';
import 'seat_store.dart';

/// Sends [record] to be kept, signed by [signer] for its table. True
/// once it is kept, by this device or by another of the table's.
Future<bool> keepGame(Signer signer, GameRecord record, {Uri? endpoint}) async {
  final table = record.spec.id;
  final answer = await askHandler('record', signer, {'table': table, 'record': jsonEncode(record.toJson())}, endpoint,
      what: table, timeout: const Duration(seconds: 30));
  return answer?.status == 200;
}

/// Why the service would not show this device a game.
enum NotShown {
  /// No subscription behind this device: looking at games is live play.
  noSubscription,

  /// Another device of the account is the one in use.
  elsewhere,

  /// The account is at that very table.
  ownGame,
}

class GameNotShown implements Exception {
  const GameNotShown(this.why);
  final NotShown why;

  @override
  String toString() => 'not shown: ${why.name}';
}

/// The game kept for [table], read but not yet checked; null when none
/// is kept, or it cannot be reached, or what came back is not a record.
/// Throws [GameNotShown] when the service will not show it here.
Future<GameRecord?> gameOf(String table, {Signer? signer, Uri? endpoint}) async {
  final asking = signer ?? await Identity.signer();
  final answer = await askHandler('review', asking, {'table': table}, endpoint, what: table, timeout: const Duration(seconds: 30));
  switch (answer?.status) {
    case 200:
      break;
    case 402:
      throw const GameNotShown(NotShown.noSubscription);
    case 409:
      throw const GameNotShown(NotShown.elsewhere);
    case 403:
      throw const GameNotShown(NotShown.ownGame);
    default:
      return null;
  }
  try {
    final record = GameRecord.parse(jsonDecode(answer!.body));
    return record?.spec.id == table ? record : null;
  } catch (_) {
    return null;
  }
}

/// The game kept for [table], for this device to look at: asked of the
/// service as [gameOf] asks, once this device is its account's in use —
/// taking the account up if need be, which asks first where the account
/// is in a game on another device (net/in_use.dart). Throws
/// [GameNotShown] for a device with no subscription, one whose account
/// is in use elsewhere, and one seated at that very table.
Future<GameRecord?> gameShownHere(String table) async {
  final signer = await Identity.signer();
  // Opened by its address, the app may not have heard back about its
  // licence yet.
  if (!Entitlement.current.live) await Entitlement.current.refresh(signer);
  if (!Entitlement.current.live) throw const GameNotShown(NotShown.noSubscription);
  if (InUse.current.standing != Use.here) await InUse.current.open(signer);
  if (InUse.current.standing != Use.here) throw const GameNotShown(NotShown.elsewhere);
  final kept = (await SeatStore.open()).load();
  if (kept != null && kept.spec.id == table && kept.spec.seatOf(signer.publicKey) != null) {
    throw const GameNotShown(NotShown.ownGame);
  }
  return gameOf(table, signer: signer);
}
