/// Signing in with Apple or Google, so a subscription follows the
/// person rather than the device (docs/06-service.md).
///
/// A household code brings a second device in while the first is at
/// hand; a sign-in is how a person gets back to their subscription when
/// it is not — a new phone, a browser that has forgotten everything. The
/// provider hands this device a token saying who signed in, minted for
/// this device's key and no other (its nonce is a hash of the key), and
/// the service checks it against the provider's own published keys.
///
/// Two handlers, one proof. `attest` puts the account on this device;
/// `supersede` moves it here from wherever it was, and brings that
/// device's subscription with it. What the service keeps of the account
/// is a keyed hash of the provider's identifier, never the identifier,
/// and nothing about it is kept here but which provider it was.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'household.dart';
import 'licence.dart';

/// Who vouches for the person signing in.
enum Provider { apple, google }

/// The nonce a provider's token has to carry for this device: the hash
/// of its key under a tag of its own. The service checks it against
/// the key the request is signed by (worker.mjs, `whoSignedIn`), so a
/// token lifted from somebody else's sign-in binds nothing to the
/// lifter.
String signInNonce(PublicKey key) => sha256Hex(utf8.encode('oh-signin/1\n$key'));

/// What a sign-in the service took came to.
class SignedIn {
  const SignedIn({required this.provider, this.superseded, this.licence});

  final Provider provider;

  /// The device the account was on before, when it was moved here.
  final PublicKey? superseded;

  /// The licence this device is owed now, if any: one that came across
  /// with the account, or the one it already had.
  final Licence? licence;
}

/// Puts the account [token] names on this device. Refused with
/// `accountElsewhere` when it is already on another, which is
/// [supersedeWith]'s to move.
Future<Said<SignedIn>> attestWith(Signer signer, Provider provider, String token, {Uri? endpoint, String service = serviceKey}) =>
    _signIn('attest', signer, provider, token, endpoint, service);

/// Moves the account [token] names to this device, and with it the
/// subscription of the device it was on. Refused with `accountNowhere`
/// when the account has never been signed in with.
Future<Said<SignedIn>> supersedeWith(Signer signer, Provider provider, String token, {Uri? endpoint, String service = serviceKey}) =>
    _signIn('supersede', signer, provider, token, endpoint, service);

Future<Said<SignedIn>> _signIn(String handler, Signer signer, Provider provider, String token, Uri? endpoint, String service) async {
  // The token is not part of what is signed: it names this key itself,
  // in its nonce, and the provider signed that.
  final answer = await askHandler(handler, signer, {'provider': provider.name, 'token': token}, endpoint);
  if (answer?.status != 200) return (answer: null, refusal: refusalOf(answer));
  final json = jsonDecode(answer!.body);
  if (json is! Map) return (answer: null, refusal: const Refused('unreachable'));
  final licence = Licence.parse(json['licence']);
  final superseded = json['superseded'];
  return (
    answer: SignedIn(
      provider: provider,
      superseded: superseded is String ? superseded : null,
      licence: licence != null && licence.holdsFor(signer.publicKey, service: service) ? licence : null,
    ),
    refusal: null,
  );
}

const _stored = 'signedInWith';

/// The provider this device last signed in with, or null. Only which
/// provider: the account itself is the service's to know, and only as
/// a hash.
Future<Provider?> signedInWith() async {
  final name = (await SharedPreferences.getInstance()).getString(_stored);
  return Provider.values.where((p) => p.name == name).firstOrNull;
}

Future<void> rememberSignIn(Provider provider) async =>
    (await SharedPreferences.getInstance()).setString(_stored, provider.name);
