/// The app's address: how long a room waits as it asks, and a room's
/// link (the pages' own addresses are router_test.dart's).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/address.dart';
import 'package:open_hearts/net/address_io.dart' show appBaseFrom;
import 'package:open_hearts/net/household.dart' show claimLink;
import 'package:open_hearts/net/licence.dart' show handlerFor;
import 'package:open_hearts/net/share.dart';
import 'package:open_hearts/net/turn.dart' show turnEndpoint;

void main() {
  test('the room waits as long as the address asks, within reason and only under e2e', () {
    const ten = Duration(seconds: 10);
    Duration waits(String url) => roomWait(Uri.parse(url), standard: ten);

    // A page somebody is playing on gets the rule, whatever it says.
    expect(waits('https://play.openhearts.game/'), ten);
    expect(waits('https://play.openhearts.game/?roomWait=45'), ten, reason: 'not without e2e');

    // A build being driven can ask for longer, which is what the
    // four-browser suite needs and nothing else does.
    expect(waits('https://play.openhearts.game/?e2e=1&roomWait=45'), const Duration(seconds: 45));
    expect(waits('https://play.openhearts.game/?e2e=1'), ten, reason: 'asking for nothing is the rule');
    expect(waits('https://play.openhearts.game/?e2e=1&roomWait=soon'), ten, reason: 'and neither is nonsense');

    // Longer, never shorter, and never much longer: it is one device's
    // read of a clock the whole room keeps.
    expect(waits('https://play.openhearts.game/?e2e=1&roomWait=1'), ten);
    expect(waits('https://play.openhearts.game/?e2e=1&roomWait=-5'), ten);
    expect(waits('https://play.openhearts.game/?e2e=1&roomWait=99999'), const Duration(minutes: 1));
  });

  test('a driven build takes the share of its beats and the target its address asks for, and no other does', () {
    double pace(String url) => paceIn(Uri.parse(url));
    int? target(String url) => targetIn(Uri.parse(url));

    // A page somebody is playing on keeps every beat and its own target.
    expect(pace('https://play.openhearts.game/?pace=0.25'), 1, reason: 'not without e2e');
    expect(target('https://play.openhearts.game/?target=1'), isNull, reason: 'not without e2e');

    // The browser suites ask for a tenth, and a game of one hand.
    expect(pace('http://play.openhearts.localhost:8123/?e2e=1&pace=0.1'), 0.1);
    expect(pace('http://play.openhearts.localhost:8123/?e2e=1&pace=0.25'), 0.25);
    expect(target('http://play.openhearts.localhost:8123/?e2e=1&target=1'), 1);

    // Production keeps its own, e2e or not: nobody's link starts a game
    // of one hand there.
    expect(pace('https://play.openhearts.game/?e2e=1&pace=0.1'), 1);
    expect(target('https://play.openhearts.game/?e2e=1&target=1'), isNull);

    // Asking for nothing, or nonsense, is the rule; and a beat is never
    // skipped outright, nor made longer.
    const here = 'http://play.openhearts.localhost:8123/';
    expect(pace('$here?e2e=1'), 1);
    expect(pace('$here?e2e=1&pace=soon'), 1);
    expect(pace('$here?e2e=1&pace=0'), 0.1);
    expect(pace('$here?e2e=1&pace=3'), 1);
    expect(target('$here?e2e=1'), isNull);
    expect(target('$here?e2e=1&target=0'), isNull);
    expect(target('$here?e2e=1&target=500'), isNull);
  });

  test('a room\'s link is the app\'s own address and the room under it, whatever page made it', () {
    expect(roomLink('KP4T9MXR', Uri.parse('https://play.openhearts.game/')).toString(), 'https://play.openhearts.game/room/KP4T9MXR');
    expect(roomLink('KP4T9MXR', Uri.parse('https://play.openhearts.game/?e2e=1')).toString(), 'https://play.openhearts.game/room/KP4T9MXR');
    expect(roomLink('KP4T9MXR', Uri.parse('http://127.0.0.1:8123/')).toString(), 'http://127.0.0.1:8123/room/KP4T9MXR');
    // A preview, which serves the app at /play/.
    expect(roomLink('KP4T9MXR', Uri.parse('https://dev.open-hearts.pages.dev/play/')).toString(),
        'https://dev.open-hearts.pages.dev/play/room/KP4T9MXR');
    expect(tableLink('0a1b2c3d4e5f60718293a4b5c6d7e8f9', Uri.parse('https://play.openhearts.game/')).toString(),
        'https://play.openhearts.game/table/0a1b2c3d4e5f60718293a4b5c6d7e8f9');
  });

  test('a phone build asks the service, and shares links, at the address its build names', () {
    // An iPhone's or an Android phone's own address is a file's, with no
    // host: nothing is asked of it and no link is built from it.
    final served = Uri.parse('file:///');
    expect(handlerFor('licence', appBaseFrom('', served)), isNull);
    expect(turnEndpoint(appBaseFrom('', served)), isNull);

    // With the config's appOrigin (build_phone.sh), the service is there
    // and so is every link a player sends.
    final base = appBaseFrom('https://play.openhearts.game', served);
    expect(handlerFor('licence', base).toString(), 'https://play.openhearts.game/api/licence');
    expect(turnEndpoint(base).toString(), 'https://play.openhearts.game/api/turn');
    expect(roomLink('ABCD', base).toString(), 'https://play.openhearts.game/room/ABCD');
    expect(tableLink('f00d', base).toString(), 'https://play.openhearts.game/table/f00d');
    expect(claimLink('XY12', base), 'https://play.openhearts.game/?claim=XY12');
  });
}
