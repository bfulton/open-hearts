/// One device at a time (docs/explanation/service.md).
///
/// An account is a person, and a person plays on one device at a time:
/// the newest device to take the account up is the one in use, at once,
/// and the one before steps back — off the relays, out of any table it
/// sat at, offline to everyone, out of the pool and out of anything it was
/// watching — and says so, with a way to take the account back. Which
/// device is in use is the service's to say: it gives the one in use an
/// activation (packages/table, licence.dart), renewed while it is open,
/// and the relay carries no device without a current one. This is that
/// activation, asked for and kept, and what the app does when it is
/// superseded.
///
/// A device at a table is asked before it is taken from: the account in
/// a game on another device is said so here, and only on the person's
/// word is that game given up.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:table/table.dart';

import '../entitlement.dart';
import 'household.dart' show askHandler;
import 'remote_config.dart' show waits;

/// Where this device stands with its account.
enum Use {
  /// Not asked, or nothing to ask with: no licence here, or the service
  /// not answering yet.
  unasked,

  /// The device in use: it holds a current activation.
  here,

  /// The account is at a table on another device, and this one asked
  /// to take it: the person is asked first.
  playingElsewhere,

  /// Another device of the account is in use; this one has stepped back.
  elsewhere,

  /// The account is suspended from live play
  /// (service/functions/suspension.mjs), as a relay said: live play is
  /// shut here until a licence is held again.
  suspended,
}

class InUse extends ChangeNotifier {
  InUse({this.renewEvery = const Duration(minutes: 20)});

  /// The one this app keeps. A global, like the entitlement, for the
  /// same reason: there is one device, and it is in use or it is not.
  static InUse current = InUse();

  /// How often the device in use says it still is: well inside the
  /// activation's hour.
  final Duration renewEvery;

  Use _standing = Use.unasked;
  Use get standing => _standing;

  Activation? _activation;

  /// The activation, while this device is the one in use.
  Activation? get activation => _standing == Use.here ? _activation : null;

  int? _profileVersion;

  /// The version of the account's profile, as the service last said with
  /// an activation (null before one): a change this device did not make
  /// is one it reads (net/account_profile.dart).
  int? get profileVersion => _profileVersion;

  /// Whether this device has stepped back for another: live play is not
  /// open here until it takes the account back.
  bool get elsewhere => _standing == Use.elsewhere || _standing == Use.playingElsewhere;

  /// Whether live play is shut here: this device stepped back for
  /// another, or the account is suspended. Nothing live stays open
  /// while it is: the pool or the room, presence, a table or a watch.
  bool get shut => elsewhere || _standing == Use.suspended;

  /// Whether the person has put the screen saying so aside for now; it
  /// comes back the next time this device is superseded.
  bool dismissed = false;

  Signer? _signer;
  Timer? _renewing;

  /// When the service last did not answer at all, if it has not since.
  DateTime? _unanswered;

  /// Whether asking the service is worth waiting on now: it answered
  /// the last time, or that was a while ago. A front door with the
  /// service down does not wait on it at every press; the relay says
  /// what it will.
  bool get worthAsking => _unanswered == null || DateTime.now().difference(_unanswered!) > const Duration(minutes: 1);
  String? _seated;
  Future<Use>? _asking;

  /// The app coming up, or the person saying "Use it here": this device
  /// takes the account, unless the account is at a table on another
  /// device, which [take] alone overrides. What it came to.
  Future<Use> open(Signer signer, {bool take = false}) {
    _signer = signer;
    return _asking ??= _ask(take ? 'take' : 'open').whenComplete(() => _asking = null);
  }

  /// Says this device still is the one in use — and, with [place],
  /// where it sits. Superseded, it steps back.
  Future<void> renew({bool place = false}) async {
    if (_standing != Use.here || _signer == null) return;
    await _ask('renew', place: place);
  }

  /// This device sat down at [table], or got up (null): told to the
  /// service, which asks another device of the account before taking
  /// the account from a game.
  void seatedAt(String? table) {
    _seated = table;
    _placing = renew(place: true);
  }

  /// The table this device has said it sits at, or null.
  String? get seatedTable => _seated;

  /// Until the service has heard the latest [seatedAt]: a game looked at
  /// just after it ended is not still this account's own game to it.
  Future<void> get placed => _placing ?? Future<void>.value();
  Future<void>? _placing;

  /// [place]: whether to say where this device sits, which a renewal on
  /// the clock leaves alone and taking the account up always says.
  Future<Use> _ask(String want, {bool place = true}) async {
    final signer = _signer!;
    final seated = _seated;
    final more = <String, Object?>{'want': want, if (place) 'seated': seated};
    final answer = await askHandler('activate', signer, more, null, what: '$want ${place ? (seated ?? '') : ''}', timeout: waits.licence);
    if (answer == null) {
      _unanswered = DateTime.now();
      return _standing;
    }
    _unanswered = null;
    Map<Object?, Object?> json;
    try {
      json = jsonDecode(answer.body) as Map;
    } catch (_) {
      return _standing;
    }
    if (answer.status == 200) {
      final act = Activation.parse(json['activation']);
      final service = Entitlement.current.service;
      if (act == null || !act.holdsFor(signer.publicKey, service: service)) return _standing;
      _activation = act;
      dismissed = false;
      final profile = json['profile'];
      final moved = profile is int && profile != _profileVersion;
      if (profile is int) _profileVersion = profile;
      if (_standing == Use.here && moved) notifyListeners();
      _set(Use.here);
      _renewing ??= Timer.periodic(renewEvery, (_) => unawaited(renew()));
      return _standing;
    }
    if (answer.status == 409 && json['seated'] == true) {
      _set(Use.playingElsewhere);
      return _standing;
    }
    if (answer.status == 409) {
      stepBack();
      return _standing;
    }
    if (answer.status == 403 && json['suspended'] == true) {
      _suspend();
      return _standing;
    }
    if (answer.status == 402) {
      _renewing?.cancel();
      _renewing = null;
      _activation = null;
      // A suspended account's devices are refused this way too: still
      // suspended, as the relay said.
      if (_standing != Use.suspended) _set(Use.unasked);
    }
    return _standing;
  }

  /// The licence here changed. A device brought into another account
  /// takes that account up, as opening the app would: what it held was
  /// for the account it left. A suspended one given a licence again has
  /// been let back, and live play opens as for any licence come in.
  void licenceChanged() {
    final licence = Entitlement.current.licence;
    if (licence != null && _standing == Use.suspended) _set(Use.unasked);
    final act = _activation;
    if (licence == null || act == null || _signer == null || act.account == licence.account) return;
    unawaited(open(_signer!));
  }

  /// Another device of the account is in use: this one steps back. Said
  /// by the service, by the relay closing this device's sockets, or by
  /// the other device's presence; whoever says it first.
  void stepBack() {
    // Suspended, there is no taking the account back here to offer.
    if (_standing == Use.elsewhere || _standing == Use.suspended) return;
    _renewing?.cancel();
    _renewing = null;
    _activation = null;
    _seated = null;
    dismissed = false;
    _set(Use.elsewhere);
  }

  /// The person put the notice aside for now: this device stays
  /// stepped back — a game on the other device goes on there — and the
  /// front door says so where live play would be.
  void putAside() {
    if (_standing == Use.playingElsewhere) stepBack();
    dismissed = true;
    notifyListeners();
  }

  /// What a relay that asks who this device is is shown
  /// (packages/table, relays.dart): the activation, for this device's
  /// own key, while it is the one in use; nothing otherwise.
  List<List<String>>? credentials(PublicKey key) {
    final act = activation;
    if (act == null || act.key != key) return null;
    return [
      ['activation', jsonEncode(act.toJson())],
    ];
  }

  /// A relay turned this device away for good, with its reason: another
  /// device of the account took it up, or the account is suspended —
  /// which shuts live play here as it does on every device of the
  /// account, the licence with it — or deleted, from another of its
  /// devices: the licence goes, and this device is one with no account.
  void turnedAway(String reason) {
    if (reason.startsWith('superseded:')) stepBack();
    if (reason.startsWith('suspended:')) _suspend();
    if (reason.startsWith('deleted:')) _deleted();
  }

  /// The account was deleted: live play shut here, and the licence off
  /// the device, as for one handed on.
  void _deleted() {
    _renewing?.cancel();
    _renewing = null;
    _activation = null;
    _seated = null;
    _set(Use.unasked);
    unawaited(Entitlement.current.forget());
  }

  /// The account is suspended, as a relay or the service said: live
  /// play shut here, and the licence off the device.
  void _suspend() {
    _renewing?.cancel();
    _renewing = null;
    _activation = null;
    _seated = null;
    _set(Use.suspended);
    unawaited(Entitlement.current.suspend());
  }

  void _set(Use s) {
    if (_standing == s) return;
    _standing = s;
    notifyListeners();
  }

  /// For a test: as new.
  @visibleForTesting
  void reset() {
    _renewing?.cancel();
    _renewing = null;
    _activation = null;
    _seated = null;
    _signer = null;
    _profileVersion = null;
    dismissed = false;
    _standing = Use.unasked;
  }
}
