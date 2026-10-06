/// Getting a token out of Apple or Google that says who signed in on
/// this device (sign_in.dart says what is done with it).
///
/// Where each is asked: on an iPhone, Sign in with Apple's own sheet;
/// on Android, Google through the system's Credential Manager; on the
/// web, Apple's sign-in page in a popup, and Google's own button, which
/// is the only way Google hands a web page a token. Every token carries
/// [signInNonce] of this device's key, so it is good for this device and
/// no other.
///
/// Which are offered is decided by the build. Each provider needs an
/// identifier made in its own console, named at build time —
/// `--dart-define=OH_GOOGLE_CLIENT_ID=<the web client id>` and
/// `--dart-define=OH_APPLE_SERVICE_ID=<the Services ID>` — and a build
/// without one does not offer that provider at all, rather than offer a
/// button that cannot work. Nothing of either provider is loaded until
/// a sign-in is offered on the screen.
library;

import 'package:flutter/widgets.dart';

import 'sign_in.dart';
import 'provider_tokens_io.dart' if (dart.library.js_interop) 'provider_tokens_web.dart' as platform;

/// Google's OAuth client for the web, which is also what an Android
/// build asks Credential Manager for a token addressed to: the one
/// audience the service checks Google's tokens against
/// (`OH_GOOGLE_AUDIENCE`). Empty in a build that does not offer Google.
const googleClientId = String.fromEnvironment('OH_GOOGLE_CLIENT_ID');

/// Apple's Services ID, which the web's sign-in is made under. An
/// iPhone signs in under the app's own bundle instead and needs no
/// identifier, but it is offered only where this is named too, so one
/// setting says whether Apple is set up at all. Empty in a build that
/// does not offer Apple.
const appleServiceId = String.fromEnvironment('OH_APPLE_SERVICE_ID');

/// The providers a build offers where it runs: Apple on an iPhone and
/// on the web, Google on Android and on the web, and each only where
/// its identifier was named.
List<Provider> providersFor({
  required bool web,
  required TargetPlatform platform,
  String google = googleClientId,
  String apple = appleServiceId,
}) =>
    [
      if (apple.isNotEmpty && (web || platform == TargetPlatform.iOS)) Provider.apple,
      if (google.isNotEmpty && (web || platform == TargetPlatform.android)) Provider.google,
    ];

/// What asking a provider came to: a token, or the person backing out
/// (neither), or the provider failing ([failed]).
typedef Asked = ({String? token, bool failed});

const backedOut = (token: null, failed: false);
const failedToAsk = (token: null, failed: true);

/// Where tokens come from on this platform.
abstract class ProviderTokens {
  /// The providers offered here, in the order they are shown.
  List<Provider> get offered;

  /// Asks [provider] for a token carrying [nonce], in its own sheet or
  /// popup. Not called for a provider that draws its own button.
  Future<Asked> ask(Provider provider, String nonce);

  /// The provider's own button, where it insists on drawing it — Google's
  /// on the web — which calls [onAsked] when it has a token. Null where
  /// the app draws the button and calls [ask].
  Widget? ownButton(Provider provider, String nonce, void Function(Asked asked) onAsked);

  /// Gets [providers] ready to be asked, once a sign-in is on the
  /// screen: on the web, their scripts. A browser opens a popup only
  /// soon after a press, so a script is not fetched after the press.
  void prepare(List<Provider> providers);
}

/// This platform's. Settable, as the service is (household.dart,
/// [askService]): a test stands its own provider here.
ProviderTokens providerTokens = platform.providerTokens();
