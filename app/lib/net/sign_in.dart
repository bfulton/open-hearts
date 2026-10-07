/// Signing in with Apple or Google, so the account follows the person
/// rather than the device (docs/06-service.md).
///
/// A household code brings a second device in while the first is at
/// hand, and a backup code when it is not; a sign-in is a backup code
/// that is never used up — a new phone, a browser that has forgotten
/// everything. The provider hands this device a token saying who signed
/// in, minted for this device's key and no other (its nonce is a hash
/// of the key), and the service checks it against the provider's own
/// published keys.
///
/// Two handlers, one proof. `attest` links the sign-in to the account
/// this device is in — one sign-in to one account, and one account to
/// one sign-in; `supersede` brings this device into the account the
/// sign-in is linked to, as a backup code would. No key moves: this
/// device keeps its own, and the service's licence says whose it is.
/// What the service keeps of the sign-in is a keyed hash of the
/// provider's identifier, never the identifier, and nothing about it is
/// kept here but which provider it was.
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
  const SignedIn({required this.provider, this.account, this.licence});

  final Provider provider;

  /// The account the sign-in is linked to, which this device is in now.
  final String? account;

  /// The licence this device is owed now, if any: the account's.
  final Licence? licence;
}

/// Links the sign-in [token] names to the account this device is in.
/// Refused with `accountElsewhere` when the sign-in is linked to another
/// account — [supersedeWith] brings this device into that one — and with
/// `otherSignIn` when this account is linked to another sign-in.
Future<Said<SignedIn>> attestWith(Signer signer, Provider provider, String token, {Uri? endpoint, String service = serviceKey}) =>
    _signIn('attest', signer, provider, token, endpoint, service);

/// Brings this device into the account the sign-in [token] names is
/// linked to. Refused with `accountNowhere` when it is linked to none,
/// and as a backup code is refused otherwise: a full account, or this
/// device in another that is still paid for.
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
  final account = json['account'];
  return (
    answer: SignedIn(
      provider: provider,
      account: account is String ? account : null,
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

/// The device's note brought in line with what the service says the
/// account is linked to ([Household.signIn]): a link made on another of
/// the account's devices, or one taken away — by Apple, when the person
/// stops using Sign in with Apple here. Returns what is noted now.
Future<Provider?> noteSignIn(String? said) async {
  final provider = Provider.values.where((p) => p.name == said).firstOrNull;
  final prefs = await SharedPreferences.getInstance();
  if (provider == null) {
    await prefs.remove(_stored);
  } else {
    await prefs.setString(_stored, provider.name);
  }
  return provider;
}
