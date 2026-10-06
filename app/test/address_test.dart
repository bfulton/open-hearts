/// The app's address: how long a room waits as it asks, and a room's
/// link (the pages' own addresses are router_test.dart's).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/address.dart';
import 'package:open_hearts/net/share.dart';

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
}
