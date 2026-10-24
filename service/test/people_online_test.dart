/// Who a device counts as online, over real sockets: the backup jurors,
/// once called, are online for a table's jury like anyone, and are not
/// people for the count a device shows (presence_relay.dart, `people`).
library;

import 'package:service/service.dart';
import 'package:table/table.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => installNativeSchnorr());
  late Relay relay;
  setUp(() async {
    relay = Relay();
    await relay.serve();
  });
  tearDown(() => relay.close());

  test('a backup juror called online is heard, and not counted as a person', () async {
    final juror = LastResortJuror(relays: [relay.url], signer: SchnorrSigner.generate())..start();
    addTearDown(juror.close);
    final device = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate());
    final other = RelayPresence(relays: [relay.url], signer: SchnorrSigner.generate());
    addTearDown(device.close);
    addTearDown(other.close);
    await Future.wait([device.ready, other.ready]);
    juror.wake('a-table');

    final everyone = {device.signer.publicKey, other.signer.publicKey, juror.signer.publicKey};
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (!device.online(withinMs: 15000).containsAll(everyone) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(device.online(withinMs: 15000), everyone, reason: 'the juror is there to be drawn');
    expect(device.people(withinMs: 15000), {device.signer.publicKey, other.signer.publicKey});
  }, timeout: const Timeout(Duration(seconds: 40)));
}
