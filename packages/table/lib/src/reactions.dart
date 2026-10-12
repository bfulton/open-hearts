/// Quick reactions at a live table: a seated player's 👍 or 😬, shown
/// for a moment beside their badge on every screen at the table and on
/// every screen watching it (docs/explanation/live-play.md).
///
/// A fixed few, and no free text, so there is nothing to moderate: a
/// reaction on the wire is a short code from [Reaction], never words,
/// and each screen says it in its own language. It is not a table
/// event. It travels on the table's own tag as an ephemeral kind of its
/// own (`TableKinds.react`), signed by the seat's device like
/// everything the seat says, and a relay forwards it and keeps nothing
/// (service/do/relay.mjs). It is not in the record, the results or the
/// game record, and nothing the protocol decides — a turn, a clock, a
/// jury — ever looks at one. Lost is lost: nobody says one again.
///
/// The rules are [ReactionRules], the same at both ends: a player
/// says one at most every [ReactionRules.gap], and a screen shows only
/// what a key seated in person at the table said ([Reaction] codes it
/// knows, about the hand it is at or the one either side), lately, and
/// not faster than that.
library;

import 'dart:convert';

import 'signing.dart';

/// The reactions there are, each a code on the wire and an emoji on the
/// screen; the word beside the emoji is the screen's own language's.
/// Appended to, never reordered or renamed: an older screen that does
/// not know a code shows nothing for it.
enum Reaction {
  nice('👍'),
  ha('😂'),
  wow('😮'),
  ouch('😬'),
  sorry('🙏'),
  gg('👋');

  const Reaction(this.emoji);

  final String emoji;

  /// What goes on the wire.
  String get code => name;

  /// The reaction [code] names, or null for one this side does not know.
  static Reaction? byCode(Object? code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// What a reaction says on the wire, as the event's content:
/// `{"react":"nice","hand":2,"turn":17}` — the code, and the moment it
/// was said at: the hand, and how many of its cards had been played.
class ReactionSaid {
  const ReactionSaid(this.reaction, {required this.hand, required this.turn});

  final Reaction reaction;
  final int hand;

  /// How many of the hand's cards had been played, 0 to 52.
  final int turn;

  /// The longest content a reaction is, in characters: the relay turns
  /// away anything longer before it reads it (service/do/relay.mjs).
  static const most = 128;

  /// The furthest a game's hand number goes, with room to spare: a
  /// game to a hundred is some twenty hands.
  static const lastHand = 9999;

  String encode() => jsonEncode({'react': reaction.code, 'hand': hand, 'turn': turn});

  /// [content] as a reaction, or null for anything else: not JSON, any
  /// other shape, a field more or less, or a code this side does not
  /// know.
  static ReactionSaid? decode(String content) {
    if (content.length > most) return null;
    try {
      final m = jsonDecode(content);
      if (m is! Map || m.length != 3) return null;
      final reaction = Reaction.byCode(m['react']);
      final hand = m['hand'];
      final turn = m['turn'];
      if (reaction == null || hand is! int || turn is! int) return null;
      if (hand < 0 || hand > lastHand || turn < 0 || turn > 52) return null;
      return ReactionSaid(reaction, hand: hand, turn: turn);
    } catch (_) {
      return null;
    }
  }
}

/// A reaction as it arrived: who signed it, its event's id, when its
/// event says it was made (seconds since the epoch), and its content —
/// not yet believed (see [ReactionRules.hear]).
typedef HeardReaction = ({PublicKey from, String id, int createdAt, String content});

/// A reaction to show: which seat said it, and what.
typedef ShownReaction = ({int seat, Reaction reaction});

/// Where reactions go and come from: the table's tag on the relay
/// (relay_transport.dart), or a test's hub (packages/table_sim, sim_reactions.dart).
abstract interface class ReactionLane {
  /// Says [content] — a [ReactionSaid], encoded — as this device.
  void sayReaction(String content);

  /// What everyone else says, as it arrives; never this device's own.
  Stream<HeardReaction> get reactions;
}

/// The rules for reactions, the sender's half and the receiver's.
///
/// A screen enforces them against everyone else whatever their device
/// does: a modified one that says a reaction every second is shown one
/// every few, and one that says a code nobody knows, or speaks for a
/// seat it does not hold, is shown nothing.
class ReactionRules {
  ReactionRules({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// What `now` is: milliseconds since the epoch, as a reaction's event
  /// is stamped in seconds since it.
  final int Function() _now;

  /// At most one reaction a player in this long, and a bubble shows for
  /// as long: a player's next reaction never lands on their last.
  static const gap = Duration(seconds: 3);
  static const shownFor = gap;

  /// What a receiver forgives of [gap]: two reactions said exactly
  /// [gap] apart can arrive a little closer than that.
  static const jitter = Duration(milliseconds: 500);

  /// Older than this, a reaction is about a moment that has gone: it
  /// was held up somewhere, or it is being said again by somebody it
  /// was not said by. And as far ahead, which is a clock that is wrong.
  static const staleAfter = Duration(seconds: 10);

  int? _saidAt;

  /// Whether this player may say a reaction now.
  bool get maySay => _saidAt == null || _now() - _saidAt! >= gap.inMilliseconds;

  /// [reaction] as the content to say, at [hand] after [turn] of its
  /// cards; null while the last one said is younger than [gap], and
  /// then nothing is said.
  String? say(Reaction reaction, {required int hand, required int turn}) {
    if (!maySay) return null;
    _saidAt = _now();
    return ReactionSaid(reaction, hand: hand.clamp(0, ReactionSaid.lastHand), turn: turn.clamp(0, 52)).encode();
  }

  /// The reactions heard lately, by id, so one that arrives twice — by
  /// two relays, or said again by someone else — is shown once.
  final _ids = <String>{};

  /// When each key's last reaction was shown here.
  final Map<PublicKey, int> _shownAt = {};

  /// [heard] as a reaction to show, or null when it is not one: said by
  /// a key not among [seated] — the keys of the seats held in person
  /// at the table now, to their seats — or something other than a
  /// reaction this side knows, about a hand not [hand] or one either
  /// side of it, stale, already heard, or said too soon after the last
  /// one shown from the same key.
  ShownReaction? hear(HeardReaction heard, {required Map<PublicKey, int> seated, required int hand}) {
    final seat = seated[heard.from];
    if (seat == null) return null;
    final said = ReactionSaid.decode(heard.content);
    if (said == null || (said.hand - hand).abs() > 1) return null;
    final now = _now();
    if ((now ~/ 1000 - heard.createdAt).abs() > staleAfter.inSeconds) return null;
    if (!_ids.add(heard.id)) return null;
    if (_ids.length > 256) _ids.remove(_ids.first);
    final last = _shownAt[heard.from];
    if (last != null && now - last < gap.inMilliseconds - jitter.inMilliseconds) return null;
    _shownAt[heard.from] = now;
    return (seat: seat, reaction: said.reaction);
  }
}
