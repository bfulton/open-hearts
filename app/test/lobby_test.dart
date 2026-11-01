/// The way from the front door to a live table (live/lobby.dart), over a
/// relay on this machine: one way in at a time, a room this device will
/// not sit in let go with everything it opened, and a game left before
/// its end still counted in the player's pace.
///
/// Plain tests rather than widget tests: the relay is a real socket, and
/// the lobby is no widget.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deal/deal.dart';
import 'package:engine/engine.dart' show Persona;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/avatar.dart';
import 'package:open_hearts/crypto/deal.dart';
import 'package:open_hearts/game_options.dart';
import 'package:open_hearts/identity.dart';
import 'package:open_hearts/l10n/l10n.dart';
import 'package:open_hearts/live/live_controller.dart';
import 'package:open_hearts/live/lobby.dart';
import 'package:open_hearts/net/in_use.dart';
import 'package:open_hearts/net/licence.dart';
import 'package:open_hearts/net/online.dart';
import 'package:open_hearts/net/remote_config.dart';
import 'package:open_hearts/net/seat_store.dart';
import 'package:open_hearts/pace_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table/table.dart';

/// A relay on this machine that answers every subscription at once and
/// refuses every event, with [refusal], or takes it where that is null.
class _Relay {
  _Relay._(this._server, this.refusal) {
    _server.listen((request) async {
      final path = request.uri.path;
      final ws = await WebSocketTransformer.upgrade(request);
      open.update(path, (n) => n + 1, ifAbsent: () => 1);
      ws.listen((raw) {
        final m = jsonDecode(raw as String) as List;
        if (m[0] == 'REQ') ws.add(jsonEncode(['EOSE', m[1]]));
        if (m[0] == 'EVENT') ws.add(jsonEncode(['OK', (m[1] as Map)['id'], refusal == null, refusal ?? '']));
      }, onDone: () => open.update(path, (n) => n - 1));
    });
  }

  static Future<_Relay> start({String? refusal}) async => _Relay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), refusal);

  final HttpServer _server;
  final String? refusal;

  /// The sockets open now, by the tag in their address.
  final Map<String, int> open = {};

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}/{tag}');

  Future<void> stop() => _server.close(force: true);
}

/// A deal that loaded, for a door that asks only whether it did.
class _Deal implements DealCrypto {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('no deal at these tables');
}

class _Worker implements DealWorker {
  @override
  bool get dead => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('no deal at these tables');
}

/// Waits for [done], for at most [within].
Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late _Relay relay;
  final keptHandlerAt = handlerAt;

  Future<void> standUp({String? refusal}) async {
    relay = await _Relay.start(refusal: refusal);
    // The relay here and nowhere else, and no service to ask.
    RemoteSettings.current = RemoteSettings()..adopt(RemoteConfig(relays: [relay.url]));
    handlerAt = (_) => null;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InUse.current = InUse();
    dealCrypto = _Deal();
    dealWorker = _Worker();
  });

  tearDown(() async {
    Online.current?.close();
    handlerAt = keptHandlerAt;
    RemoteSettings.current = RemoteSettings();
    dealCrypto = null;
    dealWorker = null;
    await relay.stop();
  });

  Lobby lobbyWith({
    Future<bool> Function()? named,
    Future<bool?> Function(LiveController controller)? seat,
    String? room,
  }) =>
      Lobby(
        who: () => (name: 'Ada', avatar: Avatar.none),
        options: () => const GameOptions(),
        named: named ?? () async => true,
        words: () => english,
        seat: seat ?? (_) async => null,
        addressChanged: () {},
        openRoom: () => room,
      );

  test('a second press while the first is still being opened does nothing', () async {
    await standUp();
    final asked = <Completer<bool>>[];
    final lobby = lobbyWith(named: () {
      final answer = Completer<bool>();
      asked.add(answer);
      return answer.future;
    });
    addTearDown(lobby.dispose);
    final first = lobby.play();
    await pumpEventQueue();
    expect(lobby.busy, isFalse, reason: 'the name is still being asked for');
    final second = lobby.play();
    final third = lobby.enter();
    await pumpEventQueue();
    expect(asked, hasLength(1), reason: 'the name asked for once, and one way in opened');
    asked.single.complete(false);
    await (first, second, third).wait;
    expect(lobby.queue, isNull);
    expect(lobby.room, isNull);
  });

  test('a room this device will not sit in is let go, its sockets and what its relays said with it', () async {
    await standUp(refusal: 'blocked: not from here');
    const code = 'ABCDEFGH';
    final lobby = lobbyWith(
      room: code,
      // The deal stops while the name is asked for: the room it opens
      // is one this device cannot sit in.
      named: () async {
        dealCrypto = null;
        return true;
      },
    );
    addTearDown(lobby.dispose);
    await lobby.enter();
    expect(lobby.room, isNotNull);
    expect(relay.open['/$code'], 1);
    await _until(() => lobby.cutOff != null);
    expect(lobby.cutOff, contains('blocked: not from here'), reason: 'the relay refused the room\'s beat');
    await _until(() => lobby.room == null);
    expect(lobby.error, isNotNull, reason: 'the door says why');
    await _until(() => relay.open['/$code'] == 0, within: const Duration(seconds: 2));
    expect(relay.open['/$code'], 0, reason: 'nothing left open under the room\'s code');
    expect(lobby.cutOff, isNull, reason: 'the refusal was that room\'s, not the next one\'s');
  });

  /// The lobby back at a seat kept from a moment ago, at a table still
  /// going with somebody else at it, the others named [names]: the way
  /// back to it after a reload. Resolves to the lobby, the table's
  /// controller, and a way to close the table's page.
  Future<({Lobby lobby, LiveController table, void Function() close})> backAtTable(Map<int, String> names) async {
    final me = await Identity.signer();
    final spec = TableSpec(
      seed: 7,
      seats: [HumanSeat(me.publicKey), BotSeat(Persona.roster[1]), HumanSeat('b' * 64), BotSeat(Persona.roster[3])],
      house: houseKey,
    );
    (await SeatStore.open()).keep(spec, {0: 'Ada', ...names}, const {});
    LiveController? seated;
    final closed = Completer<bool?>();
    final lobby = lobbyWith(seat: (controller) {
      seated = controller;
      return closed.future;
    });
    addTearDown(lobby.dispose);
    await lobby.goOnline();
    await _until(() => seated != null);
    final table = seated!;
    // As Leave does: the page goes, and the controller with it.
    return (lobby: lobby, table: table, close: () {
      closed.complete(null);
      table.dispose();
    });
  }

  test('a game left before its end still counts toward the pace', () async {
    await standUp();
    final at = await backAtTable({2: 'Bao'});
    at.table.myCardMs.addAll([2000, 4000]);
    at.close();
    await _until(() => at.lobby.pace.cards > 0);
    expect(at.lobby.pace.cards, 2, reason: 'the two cards the player took their own time over');
    expect((await PaceStore.load()).cards, 2, reason: 'kept on the device');
  });

  test('another device\'s name is cut and cleaned as this device keeps its own', () async {
    await standUp();
    final at = await backAtTable({2: ' Bao\u0007${'o' * 70} '});
    expect(at.table.seatNames[2], 'Bao${'o' * 57}', reason: 'sixty characters, nothing that is not text');
    expect(at.table.seatNames[0], 'Ada');
    at.close();
  });
}
