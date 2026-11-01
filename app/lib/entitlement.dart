/// What this device may do, and for how long (docs/explanation/service.md).
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'net/backoff.dart';
import 'net/licence.dart';
import 'net/network.dart';
import 'net/remote_config.dart' show waits;

class Entitlement extends ChangeNotifier {
  Entitlement({this.service = serviceKey, this.ask = askLicence});

  /// The one this app asks. A global, like the device's identity, for
  /// the same reason: there is one device and it has one standing.
  /// Settable, so a test can stand a service of its own behind it.
  static Entitlement current = Entitlement();

  static const _stored = 'licence';

  /// The service whose word counts, which is the build's to name.
  final String service;

  /// How the service is asked: [askLicence], unless a test stands in.
  final Future<LicenceAnswer> Function(Signer signer, {String service}) ask;

  Licence? _licence;
  PublicKey? _device;

  /// The licence this device holds, if it holds a good one.
  Licence? get licence => _licence;

  /// What every ask of the service shows besides what it asks
  /// (net/household.dart, askHandler; net/turn.dart): the licence this
  /// device holds, which the service signed and which names the account.
  /// A device just brought in by its account's object somewhere else is
  /// known there before the service's store here has heard of it
  /// (service/functions/licence.mjs, accountAsking and heldAccount).
  Map<String, Object?> get licenceShown => {'licence': ?_licence?.toJson()};

  /// Whether live play is open here. The one question the front door
  /// asks, and the only one anything outside this file should.
  bool get live => _licence != null;

  /// The last day live play is open, or null when it is not open.
  DateTime? get until => _licence?.until;

  bool _suspended = false;

  /// Whether the service has said this device's account is suspended
  /// from live play (service/functions/suspension.mjs): what the page
  /// that would sell live play says instead. Said again at every start
  /// the service is asked, and not kept.
  bool get suspended => _suspended;

  /// The licence off the device, if there is one and it is still good.
  /// Called before the first frame: nothing here touches the network.
  ///
  /// Everything else waits on this. Until it has run there is no device
  /// to hold a licence for, so nothing can be adopted and nothing is
  /// open — which is the safe way for the order to go wrong.
  Future<void> load(PublicKey device) async {
    _device = device;
    final prefs = await SharedPreferences.getInstance();
    final stored = Licence.parse(prefs.getString(_stored));
    _lapsed = stored != null && stored.key == device && stored.signedBy(service) ? stored.account : null;
    _keep(stored);
  }

  String? _lapsed;

  /// Whether this device is in an account, as far as it knows: it holds
  /// a licence, the account is suspended, or the licence it last held
  /// has run out — a lapsed subscriber's, whose account is still there
  /// to delete (subscribe_page.dart).
  bool get inAnAccount => _licence != null || _suspended || _lapsed != null;

  /// The licence the service will give, which supersedes whatever is
  /// on the device — including by expiring it, since a subscription
  /// that has stopped being renewed is one whose last licence runs
  /// out. A service that cannot be reached says nothing, and the
  /// device keeps what it has until its date.
  ///
  /// Answers whether the service answered within its few seconds
  /// (`waits.licence`). One that answers after that is still taken when
  /// it does: a slow network is not a refusal, and a subscriber whose
  /// licence came back in the seventh second is a subscriber.
  Future<bool> refresh(Signer signer) {
    final asked = ask(signer, service: service).then((said) async {
      if (said.licence != null) await adopt(said.licence!);
      if (said.suspended) await suspend();
      if (said.answered) _heard();
      return said.answered;
    });
    return asked.timeout(waits.licence, onTimeout: () => false);
  }

  Signer? _signer;
  bool _answered = false;
  bool _asking = false;
  bool _listening = false;
  final _backoff = Backoff();
  Timer? _again;

  /// Asks the service for this device's licence until it answers, as
  /// the app starts: at once, and while nothing has come back, again
  /// after a wait that doubles each time ([Backoff]) — one ask at a time, and none while the device says it has no
  /// network. Back on a network, or back in the foreground ([askAgain]),
  /// it asks at once and the waits start short again. Once the service
  /// has answered, licence or none, it is not asked again this start.
  ///
  /// Resolves when the first ask is answered or given up on, as
  /// [refresh] does.
  Future<bool> keepAsking(Signer signer) {
    _signer = signer;
    if (!_listening) {
      _listening = true;
      whenOnline(askAgain);
    }
    return _askNow();
  }

  /// Ask now, if the service has not answered yet: the device is back
  /// in the foreground, or on a network again.
  void askAgain() {
    if (_signer == null || _answered) return;
    _backoff.reset();
    unawaited(_askNow());
  }

  Future<bool> _askNow() async {
    final signer = _signer;
    if (signer == null || _answered || _asking) return _answered;
    _again?.cancel();
    // Nobody to ask with no network: the next ask is when one is back.
    if (deviceOffline()) return false;
    _asking = true;
    final bool answered;
    try {
      answered = await refresh(signer);
    } finally {
      _asking = false;
    }
    if (!answered && !_answered) {
      _again = Timer(_backoff.next(), () => unawaited(_askNow()));
    }
    return answered;
  }

  /// The service has answered: nothing more to ask it this start.
  void _heard() {
    _answered = true;
    _again?.cancel();
    _again = null;
  }

  /// A licence from anywhere — the service, a purchase just made, a
  /// ticket claimed from another device — kept if it is this device's
  /// and this service's. Returns whether it was.
  Future<bool> adopt(Licence licence) async {
    if (!_keep(licence)) return false;
    await (await SharedPreferences.getInstance()).setString(_stored, licence.encoded);
    return true;
  }

  /// The account suspended from live play, as the service or a relay
  /// says: the licence off the device, as for one handed on — it is not
  /// a licence the device may play on, whatever its date — and the
  /// suspension said where live play would be sold.
  Future<void> suspend() async {
    _suspended = true;
    await forget();
  }

  /// Nothing held here any more: the licence off the device, and live
  /// play shut. For a device being handed on.
  Future<void> forget() async {
    _licence = null;
    _lapsed = null;
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
    // A licence held is live play open: whatever was said before, not
    // a suspension now.
    if (held != null) _suspended = false;
    if (was != held) notifyListeners();
    return held != null;
  }
}
