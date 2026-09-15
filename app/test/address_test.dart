/// The room in the address bar: what the address becomes on the way
/// into a room and on the way out of one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/address.dart';

void main() {
  test('a room goes into the address and comes out of it, and the rest is left alone', () {
    expect(roomAddress('KP4T9MXR', Uri.parse('https://openhearts.game/play/')), '/play/?room=KP4T9MXR');
    // A build being driven stays driven across the refresh the address
    // is there for.
    expect(roomAddress('KP4T9MXR', Uri.parse('https://openhearts.game/play/?e2e=1#/')), '/play/?e2e=1&room=KP4T9MXR#/');
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
