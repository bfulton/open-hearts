/// Tokens on a phone: Sign in with Apple's own sheet on an iPhone, and
/// Google through Android's Credential Manager.
///
/// Google is reached through its Android plugin and the plugin's
/// interface rather than through `google_sign_in` itself: that package
/// brings its web half with it, and the web half fetches Google's script
/// into every page the app is opened in, signing in or not. The web asks
/// Google its own way, and only when a sign-in is on the screen
/// (provider_tokens_web.dart).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'provider_tokens.dart';
import 'sign_in.dart';

ProviderTokens providerTokens() => _PhoneTokens();

class _PhoneTokens implements ProviderTokens {
  /// Google's sign-in is set up once for the life of the app, and the
  /// nonce is part of it — which is no loss, since this device has one
  /// key and so one nonce.
  Future<void>? _google;

  @override
  List<Provider> get offered => providersFor(web: false, platform: defaultTargetPlatform);

  @override
  Future<Asked> ask(Provider provider, String nonce) => switch (provider) {
        Provider.apple => _apple(nonce),
        Provider.google => _googleToken(nonce),
      };

  @override
  Widget? ownButton(Provider provider, String nonce, void Function(Asked asked) onAsked) => null;

  @override
  void prepare(List<Provider> providers) {}

  /// No scopes: neither a name nor an email is asked for, since neither
  /// is kept. The token's subject is all the service reads.
  Future<Asked> _apple(String nonce) async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(scopes: const [], nonce: nonce);
      final token = credential.identityToken;
      return token == null ? failedToAsk : (token: token, failed: false);
    } on SignInWithAppleAuthorizationException catch (e) {
      return e.code == AuthorizationErrorCode.canceled ? backedOut : failedToAsk;
    } catch (_) {
      return failedToAsk;
    }
  }

  Future<Asked> _googleToken(String nonce) async {
    final google = GoogleSignInPlatform.instance;
    try {
      // On Android the token is addressed to the server's client — the
      // web client id — and the app itself is known to Google by its
      // package name and signing certificate.
      await (_google ??= google.init(InitParameters(serverClientId: googleClientId, nonce: nonce)));
    } catch (_) {
      // Not kept: the next press tries again.
      _google = null;
      return failedToAsk;
    }
    try {
      final signed = await google.authenticate(const AuthenticateParameters());
      final token = signed.authenticationTokens.idToken;
      return token == null ? failedToAsk : (token: token, failed: false);
    } on GoogleSignInException catch (e) {
      return switch (e.code) {
        GoogleSignInExceptionCode.canceled || GoogleSignInExceptionCode.interrupted => backedOut,
        _ => failedToAsk,
      };
    } catch (_) {
      return failedToAsk;
    }
  }
}
