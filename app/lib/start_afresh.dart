/// This device as new, once its account is deleted from it
/// (subscribe_page.dart): nothing of the account left behind here.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'build_info.dart' show reloadPage;
import 'entitlement.dart';
import 'secret_store.dart';

/// What says, on a device, that it was started afresh: kept through the
/// wipe, so the page that brings a device along from the app's old
/// address (web/carry.js) does not bring the deleted one back.
const startedAfreshKey = 'device_started_afresh';

/// Everything Open Hearts keeps on this device gone — its key, its
/// licence, its name and picture, the games played alone, the players it
/// blocked, its settings — so it comes back as a new player. On a phone
/// the key is in the secret store, not among the preferences
/// (secret_store.dart), and goes from there as well as from them: a key
/// that could not be deleted is thrown, not left behind unsaid. On the web
/// the page is then loaded again, as new. A phone build cannot start
/// itself again; true when the app has to be closed and opened again
/// for that, until when nothing of it is to be used.
Future<bool> startAfresh({DateTime? now}) async {
  await Entitlement.current.forget();
  await SecretStore.current?.delete();
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await prefs.setString(startedAfreshKey, (now ?? DateTime.now()).toUtc().toIso8601String().substring(0, 10));
  if (!kIsWeb) return true;
  reloadPage();
  return false;
}
