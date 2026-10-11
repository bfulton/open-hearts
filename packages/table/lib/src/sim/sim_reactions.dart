/// Reactions among simulated devices (reactions.dart): what one lane
/// on the hub says, every other lane hears, stamped with the hub's
/// clock as a relay's event is stamped by its sender's. No relay, no
/// signatures — the hub says who said it, which is all a lane is asked.
library;

import 'dart:async';

import '../reactions.dart';
import '../signing.dart';

class ReactionHub {
  ReactionHub({required this.nowMs});

  /// Milliseconds since the epoch, as the devices on the hub tell time.
  final int Function() nowMs;

  final Map<PublicKey, StreamController<HeardReaction>> _lanes = {};
  var _said = 0;

  /// Everything said on the hub, in order, by whom.
  final List<({PublicKey from, String content})> said = [];

  /// The lane of the device keyed [key]: watching, or seated.
  ReactionLane lane(PublicKey key) => _Lane(this, key, _lanes.putIfAbsent(key, StreamController<HeardReaction>.broadcast));

  /// [content] said by [from], to everyone else: what a device the hub
  /// has no lane for — a stranger, a forger — can still put on a tag.
  void sayAs(PublicKey from, String content, {int? createdAt}) {
    said.add((from: from, content: content));
    final heard = (from: from, id: 'r${_said++}', createdAt: createdAt ?? nowMs() ~/ 1000, content: content);
    for (final MapEntry(key: key, value: lane) in _lanes.entries) {
      if (key != from && !lane.isClosed) lane.add(heard);
    }
  }

  void close() {
    for (final lane in _lanes.values) {
      lane.close();
    }
  }
}

class _Lane implements ReactionLane {
  _Lane(this._hub, this._key, this._heard);

  final ReactionHub _hub;
  final PublicKey _key;
  final StreamController<HeardReaction> _heard;

  @override
  void sayReaction(String content) => _hub.sayAs(_key, content);

  @override
  Stream<HeardReaction> get reactions => _heard.stream;
}
