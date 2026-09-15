/// The room in the address bar: what the address becomes on the way
/// into a room and on the way out of one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/address.dart';

void main() {
  test('the room waits as long as the address asks, within reason and only under e2e', () {
    const ten = Duration(seconds: 10);
    Duration waits(String url) => roomWait(Uri.parse(url), standard: ten);

    // A page somebody is playing on gets the rule, whatever it says.
    expect(waits('https://openhearts.game/play/'), ten);
    expect(waits('https://openhearts.game/play/?roomWait=45'), ten, reason: 'not without e2e');

    // A build being driven can ask for longer, which is what the
    // four-browser suite needs and nothing else does.
    expect(waits('https://openhearts.game/play/?e2e=1&roomWait=45'), const Duration(seconds: 45));
    expect(waits('https://openhearts.game/play/?e2e=1'), ten, reason: 'asking for nothing is the rule');
    expect(waits('https://openhearts.game/play/?e2e=1&roomWait=soon'), ten, reason: 'and neither is nonsense');

    // Longer, never shorter, and never much longer: it is one device's
    // read of a clock the whole room keeps.
    expect(waits('https://openhearts.game/play/?e2e=1&roomWait=1'), ten);
    expect(waits('https://openhearts.game/play/?e2e=1&roomWait=-5'), ten);
    expect(waits('https://openhearts.game/play/?e2e=1&roomWait=99999'), const Duration(minutes: 1));
  });

  test('a room goes into the address and comes out of it, and the rest is left alone', () {
    expect(roomAddress('KP4T9MXR', Uri.parse('https://openhearts.game/play/')), '/play/?room=KP4T9MXR');
    // A build being driven stays driven across the refresh the address
    // is there for.
    expect(roomAddress('KP4T9MXR', Uri.parse('https://openhearts.game/play/?e2e=1#/')), '/play/?e2e=1&room=KP4T9MXR#/');
    // Including what it was driven with: a suite's room keeps its
    // longer wait across the refresh it is about to be asked for.
    expect(roomAddress('KP4T9MXR', Uri.parse('https://openhearts.game/play/?e2e=1&roomWait=45')),
        '/play/?e2e=1&roomWait=45&room=KP4T9MXR');
    // A second room replaces the first rather than joining it.
    expect(roomAddress('WXY23TUV', Uri.parse('https://openhearts.game/play/?room=KP4T9MXR')), '/play/?room=WXY23TUV');
    // Out of the room: the link goes, and a refresh is the front door.
    expect(roomAddress(null, Uri.parse('https://openhearts.game/play/?e2e=1&room=KP4T9MXR')), '/play/?e2e=1');
    expect(roomAddress(null, Uri.parse('https://openhearts.game/play/?room=KP4T9MXR')), '/play/');
    // Nothing of a bare address is lost either, which would leave it
    // where it was, room and all.
    expect(roomAddress(null, Uri.parse('https://openhearts.game?room=KP4T9MXR')), '/');
  });
}
