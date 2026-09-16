/// What this device may do, and for how long (docs/06-service.md).
///
/// Solo play is free and stays free — the bots, the records, the
/// verifiable deal, the engine itself. Live play is a subscription,
/// and what a subscribed device holds is a [Licence]: a short signed
/// statement with a date on it, read off the device before the first
/// frame and refreshed from the service behind it.
///
/// Read first, asked second, in that order and never the other way.
/// The front door must be able to answer before it is drawn, and a
/// device on a train must be able to answer at all.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'net/licence.dart';

class Entitlement extends ChangeNotifier {
  Entitlement({this.service = serviceKey});

  /// The one this app asks. A global, like the device's identity, for
  /// the same reason: there is one device and it has one standing.
  /// Settable, so a test can stand a service of its own behind it.
  static Entitlement current = Entitlement();

  static const _stored = 'licence';

  /// The service whose word counts, which is the build's to name.
  final String service;

  Licence? _licence;
  PublicKey? _device;

  /// The licence this device holds, if it holds a good one.
  Licence? get licence => _licence;

  /// Whether live play is open here. The one question the front door
  /// asks, and the only one anything outside this file should.
  bool get live => _licence != null;

  /// The last day live play is open, or null when it is not open.
  DateTime? get until => _licence?.until;

  /// The licence off the device, if there is one and it is still good.
  /// Called before the first frame: nothing here touches the network.
  ///
  /// Everything else waits on this. Until it has run there is no device
  /// to hold a licence for, so nothing can be adopted and nothing is
  /// open — which is the safe way for the order to go wrong.
  Future<void> load(PublicKey device) async {
    _device = device;
    final prefs = await SharedPreferences.getInstance();
    _keep(Licence.parse(prefs.getString(_stored)));
  }

  /// The licence the service will give, which supersedes whatever is
  /// on the device — including by expiring it, since a subscription
  /// that has stopped being renewed is one whose last licence runs
  /// out. A service that cannot be reached says nothing, and the
  /// device keeps what it has until its date.
  Future<void> refresh(Signer signer, {Uri? endpoint}) async {
    final fresh = await fetchLicence(signer, endpoint: endpoint, service: service);
    if (fresh != null) await adopt(fresh);
  }

  /// A licence from anywhere — the service, a purchase just made, a
  /// ticket claimed from another device — kept if it is this device's
  /// and this service's. Returns whether it was.
  Future<bool> adopt(Licence licence) async {
    if (!_keep(licence)) return false;
    await (await SharedPreferences.getInstance()).setString(_stored, licence.encoded);
    return true;
  }

  /// Nothing held here any more: the licence off the device, and live
  /// play shut. For a device being handed on.
  Future<void> forget() async {
    _licence = null;
    await (await SharedPreferences.getInstance()).remove(_stored);
    notifyListeners();
  }

  /// Keeps [licence] if it holds for this device now. Whatever does
  /// not hold leaves nothing behind: a licence that has run out is not
  /// a lesser licence, it is none.
  bool _keep(Licence? licence) {
    final device = _device;
    final held = licence != null && device != null && licence.holdsFor(device, service: service) ? licence : null;
    final was = _licence;
    _licence = held;
    if (was != held) notifyListeners();
    return held != null;
  }
}
