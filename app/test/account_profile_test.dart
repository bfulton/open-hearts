/// The profile is the account's (docs/06-service.md;
/// net/account_profile.dart): a newer one from the account is taken
/// over this device's, a change made here is kept here and sent — later,
/// if it cannot go now — a device brought into an account takes its
/// profile, and an account with none takes the first device's.
///
/// The service is a stand-in that keeps one profile and numbers its
/// writes, as the real one does. Its own rules — who may write, the
/// shape, the allowance — are proved where they live, in
/// `node --test service/functions` (profile.test.mjs).
library;

import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/entitlement.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/net/account_profile.dart';
import 'package:open_hearts/net/household.dart';
import 'package:open_hearts/net/in_use.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/profile_page.dart';
import 'package:open_hearts/stats.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

import 'home_page_test.dart' show licenceThisDevice;
import 'in_use_test.dart' show activationFor;

const _service = 'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';

/// The account the stand-in licence is for (home_page_test.dart).
final _account = '0a' * 16;

/// The service's half of it: one account's profile and its version,
/// written only while this device is the one in use.
class Kept {
  Map<String, Object?>? profile;
  int version = 0;
  bool reachable = true;
  bool inUse = true;

  /// What a write is refused with instead, when set.
  String? refusal;

  /// What was asked, in order: `read` or `write`.
  final asked = <String>[];

  Future<({int status, String body})> ask(Uri url, String body) async {
    if (!reachable) throw const SocketException('nobody there');
    final json = jsonDecode(body) as Map;
    final key = json['key'] as String;
    if (url.path == '/api/activate') {
      return (status: 200, body: jsonEncode({'activation': activationFor(key)}));
    }
    if (url.path != '/api/profile') return (status: 404, body: '{"error":"no such handler"}');
    final text = json['profile'];
    // What is written is what was signed.
    expect(schnorrVerifier(key, requestDigest('profile', key, json['at'] as int, text is String ? text : ''), json['sig'] as String), isTrue);
    if (text is! String) {
      asked.add('read');
      return (status: 200, body: jsonEncode(profile == null ? {'profile': null, 'version': 0} : {'profile': profile, 'version': version}));
    }
    asked.add('write');
    if (refusal != null) return (status: 400, body: jsonEncode({'error': refusal}));
    if (!inUse) return (status: 409, body: '{"error":"superseded: another device of this account is in use"}');
    profile = (jsonDecode(text) as Map).cast<String, Object?>();
    version++;
    return (status: 200, body: jsonEncode({'profile': profile, 'version': version}));
  }
}

Kept standUp() {
  final kept = Kept();
  final wasAt = handlerAt;
  final wasAsk = askService;
  handlerAt = (handler) => Uri.parse('https://service.test/api/$handler');
  askService = kept.ask;
  addTearDown(() {
    handlerAt = wasAt;
    askService = wasAsk;
  });
  return kept;
}

/// What the profile page leaves this device with.
Future<({String? name, Avatar avatar})> here() async => (name: await Identity.name(), avatar: await Identity.avatar());

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Entitlement.current = Entitlement(service: _service);
    InUse.current = InUse();
    AccountProfile.current = AccountProfile();
  });
  tearDown(() {
    AccountProfile.current.reset();
    Entitlement.current = Entitlement();
    InUse.current = InUse();
    AccountProfile.current = AccountProfile();
  });

  test('the account\'s profile, newer than the one here, is taken over it; one no newer is not taken again', () async {
    final kept = standUp();
    await licenceThisDevice();
    await Identity.setName('Ada');
    kept
      ..profile = {'name': 'Bao', 'icon': 'rocket', 'color': 2}
      ..version = 4;
    var told = 0;
    AccountProfile.current.addListener(() => told++);
    await AccountProfile.current.sync();
    expect(await here(), (name: 'Bao', avatar: const Avatar(icon: 'rocket', color: 2)));
    expect(told, 1, reason: 'the screens that show it are told');
    expect((await SharedPreferences.getInstance()).getString('profile_account'), _account);
    // Changed on this device by hand, not on the profile page: the same
    // version again is nothing new.
    await Identity.setName('Someone');
    await AccountProfile.current.sync();
    expect(await Identity.name(), 'Someone');
    // A newer one is.
    kept
      ..profile = {'name': 'Bao B.'}
      ..version = 5;
    await AccountProfile.current.sync();
    expect(await here(), (name: 'Bao B.', avatar: Avatar.none));
    expect(kept.asked, ['read', 'read', 'read'], reason: 'never written over by a read');
  });

  test('a change on the profile page is kept here at once and sent as the account\'s', () async {
    final kept = standUp();
    await licenceThisDevice();
    kept
      ..profile = {'name': 'Ada'}
      ..version = 1;
    await AccountProfile.current.sync();
    final picture = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
    await AccountProfile.current.keep('  Ada L.  ', Avatar(icon: 'star', picture: picture));
    expect(await here(), (name: 'Ada L.', avatar: Avatar(icon: 'star', picture: picture)), reason: 'kept before anything is asked');
    await AccountProfile.current.sync();
    expect(kept.profile, {'name': 'Ada L.', 'icon': 'star', 'picture': base64Encode(picture)});
    expect(kept.version, 2);
    // Sent once: the next round reads, and finds nothing newer.
    await AccountProfile.current.sync();
    expect(kept.asked, ['read', 'write', 'read']);
    expect(await Identity.name(), 'Ada L.');
  });

  test('a change that cannot go now goes later: offline, or while another device is in use', () async {
    final kept = standUp();
    await licenceThisDevice();
    AccountProfile.current.watch();
    kept.reachable = false;
    await AccountProfile.current.keep('Ada', const Avatar(icon: 'moon'));
    await AccountProfile.current.sync();
    expect(kept.profile, isNull);
    expect(await Identity.name(), 'Ada', reason: 'still this device\'s');
    // Back online, but another device of the account is the one in use.
    kept
      ..reachable = true
      ..inUse = false;
    await AccountProfile.current.retry();
    expect(kept.profile, isNull);
    // Nor by a service part way through a deploy, whose account's turn
    // does not know the question yet.
    kept.refusal = 'not a household operation';
    await AccountProfile.current.retry();
    kept.refusal = null;
    // This device takes the account back: what was waiting goes.
    kept.inUse = true;
    await InUse.current.open(await Identity.signer());
    await AccountProfile.current.sync();
    expect(kept.profile, {'name': 'Ada', 'icon': 'moon'});
    expect(kept.version, 1);
    kept.asked.clear();
    await AccountProfile.current.retry();
    expect(kept.asked, isEmpty, reason: 'nothing is waiting any more');
  });

  test('a device brought into an account takes the account\'s profile over its own', () async {
    final kept = standUp();
    final me = (await Identity.signer()).publicKey;
    await Entitlement.current.load(me);
    // Played alone until now, with a profile of its own — and a change
    // it never sent to an account it was once in.
    await Identity.setName('Solo');
    await Identity.setAvatar(const Avatar(icon: 'cake', color: 1));
    await (await SharedPreferences.getInstance()).setString('profile_unsent', 'ff' * 16);
    kept
      ..profile = {'name': 'Ada', 'icon': 'rocket'}
      ..version = 7;
    AccountProfile.current.watch();
    // Brought in: a code, a backup code, a sign-in, a purchase restored
    // all end in a licence for the account.
    await licenceThisDevice();
    await AccountProfile.current.sync();
    expect(await here(), (name: 'Ada', avatar: const Avatar(icon: 'rocket')));
    expect(kept.asked.contains('write'), isFalse, reason: 'the account\'s is not written over');
    expect(kept.version, 7);
  });

  test('an account with no profile yet takes the first device\'s; a device with nothing to give gives nothing', () async {
    final kept = standUp();
    await licenceThisDevice();
    await AccountProfile.current.sync();
    expect(kept.asked, ['read'], reason: 'no name and no look: nothing to send');
    expect(kept.profile, isNull);
    await Identity.setName('Ada');
    await Identity.setAvatar(const Avatar(color: 4));
    await AccountProfile.current.sync();
    expect(kept.profile, {'name': 'Ada', 'color': 4});
    expect(kept.version, 1);
    // And it is now the account's: this device does not take its own
    // back as something new.
    await AccountProfile.current.sync();
    expect(kept.asked, ['read', 'read', 'write', 'read']);
  });

  test('a profile the service will never take is not sent again and again', () async {
    final kept = standUp();
    await licenceThisDevice();
    kept.refusal = 'not a picture';
    await AccountProfile.current.keep('Ada', Avatar(picture: Uint8List.fromList([1, 2, 3])));
    await AccountProfile.current.sync();
    kept.asked.clear();
    await AccountProfile.current.retry();
    expect(kept.asked, isEmpty);
    expect(await Identity.name(), 'Ada', reason: 'still this device\'s');
  });

  testWidgets('the profile page: left as it was, nothing is sent; changed, it is kept here and sent', (tester) async {
    final kept = standUp();
    await tester.runAsync(() async {
      await licenceThisDevice();
      await Identity.setName('Ada');
    });
    Future<void> openAndDone(Future<void> Function() change) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProfilePage(stats: Stream<PlayerStats>.empty()))),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await change();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    }

    await openAndDone(() async {});
    expect(kept.asked, isEmpty, reason: 'nothing changed, nothing written');
    await openAndDone(() async {
      expect(find.text('Ada'), findsWidgets, reason: 'the page shows what the device holds');
      await tester.enterText(find.byType(TextField), 'Ada Lovelace');
      await tester.pumpAndSettle();
    });
    expect(await tester.runAsync(Identity.name), 'Ada Lovelace');
    await tester.runAsync(AccountProfile.current.sync);
    expect(kept.profile, {'name': 'Ada Lovelace'});
    expect(kept.asked.first, 'write');
  });

  test('a device with no subscription keeps its profile to itself', () async {
    final kept = standUp();
    await Entitlement.current.load((await Identity.signer()).publicKey);
    await AccountProfile.current.keep('Solo', const Avatar(icon: 'cake'));
    await AccountProfile.current.sync();
    await AccountProfile.current.retry();
    expect(kept.asked, isEmpty);
    expect(await here(), (name: 'Solo', avatar: const Avatar(icon: 'cake')));
    // And a name is kept as a table carries one: trimmed, and no longer.
    await AccountProfile.current.keep('${'x' * 70}  ', Avatar.none);
    expect(await Identity.name(), 'x' * Identity.longestName);
  });
}
