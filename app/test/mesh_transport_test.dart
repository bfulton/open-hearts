/// Channels through TURN alone (net/mesh_transport.dart): no peer is
/// ever handed another's address.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/mesh_transport.dart';
import 'package:open_hearts/net/turn.dart';

void main() {
  const turn = {
    'urls': ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'],
    'username': 'u',
    'credential': 'c',
  };
  const stun = {
    'urls': ['stun:stun.cloudflare.com:3478']
  };

  test('a connection relays through TURN, so no address of its own is gathered', () {
    expect(MeshTransport.rtcConfiguration([turn]), {
      'iceServers': [turn],
      'iceTransportPolicy': 'relay',
    });
    expect(MeshTransport.makesChannels([turn]), isTrue);
  });

  test('no TURN server: no channels at all, and the relay carries the table', () {
    expect(MeshTransport.makesChannels(const []), isFalse);
    expect(MeshTransport.makesChannels([stun]), isFalse, reason: 'STUN alone would hand out the address');
  });

  test('a TURN server is told from a STUN one by its scheme', () {
    expect(MeshTransport.isTurn(turn), isTrue);
    expect(MeshTransport.isTurn({'urls': 'turns:x:443'}), isTrue);
    expect(MeshTransport.isTurn(stun), isFalse);
  });

  test('credentials are asked of the app\'s own origin: the site, or the rig on this machine', () {
    expect(turnEndpoint(Uri.parse('https://play.openhearts.game/room/KP4T9MXR')), Uri.parse('https://play.openhearts.game/api/turn'));
    expect(turnEndpoint(Uri.parse('http://127.0.0.1:4321/')), Uri.parse('http://127.0.0.1:4321/api/turn'));
    expect(turnEndpoint(Uri.parse('http://localhost:4321/')), Uri.parse('http://localhost:4321/api/turn'));
    expect(turnEndpoint(Uri.parse('http://play.openhearts.localhost:4321/')), Uri.parse('http://play.openhearts.localhost:4321/api/turn'));
    expect(turnEndpoint(Uri.parse('http://example.com/')), isNull, reason: 'never in the clear over the network');
  });
}
