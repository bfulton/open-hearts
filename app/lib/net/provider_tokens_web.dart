/// Tokens in a browser: Apple's sign-in page in a popup, and Google's
/// own button.
///
/// Neither provider's script is part of the page. Each is fetched from
/// the provider when a sign-in it offers is first on the screen, and
/// never for anybody who does not come to one — a person playing a game
/// has not asked to be introduced to Apple or Google.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'provider_tokens.dart';
import 'sign_in.dart';

ProviderTokens providerTokens() => _BrowserTokens();

const _appleScript = 'https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js';
const _googleScript = 'https://accounts.google.com/gsi/client';

final _loading = <String, Future<void>>{};

/// [src] on the page, once; fetched again after a failure, rather than
/// failed for the rest of the page's life.
Future<void> _script(String src) => _loading[src] ??= _append(src).catchError((Object e) {
      _loading.remove(src);
      throw e;
    });

Future<void> _append(String src) {
  final done = Completer<void>();
  final document = globalContext['document'] as JSObject;
  final script = document.callMethod<JSObject>('createElement'.toJS, 'script'.toJS);
  script['src'] = src.toJS;
  script['async'] = true.toJS;
  script['onload'] = ((JSAny? _) => done.complete()).toJS;
  script['onerror'] = ((JSAny? _) => done.completeError(StateError('$src did not load'))).toJS;
  (document['head'] as JSObject).callMethod<JSAny?>('appendChild'.toJS, script);
  return done.future;
}

/// Where Apple's popup says it came back to: the app's own address,
/// which is the page's base (`/play/` on the site). It has to be one of
/// the Return URLs on the Services ID, exactly.
Uri _returnUrl() {
  final at = Uri.base;
  return Uri(scheme: at.scheme, host: at.host, port: at.hasPort ? at.port : null, path: at.path.isEmpty ? '/' : at.path);
}

class _BrowserTokens implements ProviderTokens {
  @override
  List<Provider> get offered => providersFor(web: true, platform: defaultTargetPlatform);

  @override
  void prepare(List<Provider> providers) {
    for (final p in providers) {
      unawaited(_script(p == Provider.apple ? _appleScript : _googleScript).catchError((_) {}));
    }
  }

  @override
  Future<Asked> ask(Provider provider, String nonce) async {
    // Google's token comes only from its own button, below.
    if (provider != Provider.apple) return failedToAsk;
    try {
      await _script(_appleScript);
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [],
        nonce: nonce,
        webAuthenticationOptions: WebAuthenticationOptions(clientId: appleServiceId, redirectUri: _returnUrl()),
      );
      final token = credential.identityToken;
      return token == null ? failedToAsk : (token: token, failed: false);
    } on SignInWithAppleCredentialsException catch (e) {
      // Apple's own words for a popup shut or a sign-in turned down.
      final shut = e.message.contains('popup_closed_by_user') || e.message.contains('user_cancelled_authorize');
      return shut ? backedOut : failedToAsk;
    } catch (_) {
      return failedToAsk;
    }
  }

  @override
  Widget? ownButton(Provider provider, String nonce, void Function(Asked asked) onAsked) =>
      provider == Provider.google ? _GoogleButton(nonce: nonce, onAsked: onAsked) : null;
}

/// Google Identity Services is set up once a page, and tells whichever
/// button is on the screen now.
bool _googleReady = false;
void Function(Asked asked)? _googleListener;

void _setUpGoogle(String nonce) {
  if (_googleReady) return;
  final id = _googleId();
  if (id == null) return;
  id.callMethod<JSAny?>(
    'initialize'.toJS,
    {
      'client_id': googleClientId,
      'nonce': nonce,
      'auto_select': false,
      'use_fedcm_for_button': true,
    }.jsify() as JSObject
      ..['callback'] = ((JSObject response) {
        final token = response['credential'];
        _googleListener?.call(token.isA<JSString>() ? (token: (token as JSString).toDart, failed: false) : failedToAsk);
      }).toJS,
  );
  _googleReady = true;
}

/// `google.accounts.id`, once the script is on the page.
JSObject? _googleId() {
  final google = globalContext['google'];
  if (google == null || !google.isA<JSObject>()) return null;
  final accounts = (google as JSObject)['accounts'];
  if (accounts == null || !accounts.isA<JSObject>()) return null;
  final id = (accounts as JSObject)['id'];
  return id != null && id.isA<JSObject>() ? id as JSObject : null;
}

class _GoogleButton extends StatefulWidget {
  const _GoogleButton({required this.nonce, required this.onAsked});

  final String nonce;
  final void Function(Asked asked) onAsked;

  @override
  State<_GoogleButton> createState() => _GoogleButtonState();
}

class _GoogleButtonState extends State<_GoogleButton> {
  @override
  void initState() {
    super.initState();
    _googleListener = widget.onAsked;
  }

  @override
  void didUpdateWidget(_GoogleButton old) {
    super.didUpdateWidget(old);
    _googleListener = widget.onAsked;
  }

  @override
  void dispose() {
    if (_googleListener == widget.onAsked) _googleListener = null;
    super.dispose();
  }

  Future<void> _draw(Object element, String locale, double width) async {
    try {
      await _script(_googleScript);
    } catch (_) {
      widget.onAsked(failedToAsk);
      return;
    }
    _setUpGoogle(widget.nonce);
    _googleId()?.callMethod<JSAny?>(
      'renderButton'.toJS,
      element as JSObject,
      {
        'type': 'standard',
        'theme': 'filled_black',
        'size': 'large',
        'shape': 'pill',
        'text': 'signin_with',
        'logo_alignment': 'center',
        'width': width.clamp(200, 400).round(),
        'locale': locale,
      }.jsify(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    return LayoutBuilder(
      builder: (context, box) => SizedBox(
        height: 44,
        child: HtmlElementView.fromTagName(
          tagName: 'div',
          onElementCreated: (element) => unawaited(_draw(element, locale, box.maxWidth)),
        ),
      ),
    );
  }
}
