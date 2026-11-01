/// Watching a table being played, from outside it.
///
/// Nobody who watches sits at the table or reaches its players: a
/// watcher says on the table's tag that it is watching ([TableKinds
/// .watch], `{"watching": true, "licence": …}`), and one seated player's device
/// answers with what anyone at the table can see — the names, the
/// scores, the cards played this hand, whose turn it is, and the keys
/// the seats are held by, which is whose reactions to show
/// (reactions.dart) — as a [WatchedTable], again after every move while
/// anyone has said so in the last minute. Nothing hidden is in it: no
/// hand, no pass, no deal.
///
/// A view is a player's account, signed by their key, not a proof:
/// the proof is the record, checked when the game is over (record.dart,
/// game_record.dart). So it is read strictly — a view that does not
/// parse is dropped — and believed only as far as a scoreboard is.
///
/// Watching is live play, which is a subscription's: a watcher says it
/// with its own device's key and licence, and is answered only where
/// the licence holds for that key and names an account not seated at
/// the table — nobody watches their own game from another device
/// (docs/explanation/live-play.md). The relay carries no device the service has
/// not vouched for in the first place (docs/explanation/service.md).
library;

import 'dart:async';

import 'package:engine/engine.dart';

import 'client.dart';
import 'licence.dart';
import 'names.dart';
import 'signing.dart';
import 'spec.dart';

class WatchedTable {
  const WatchedTable({
    required this.table,
    required this.target,
    required this.seq,
    required this.hand,
    required this.phase,
    required this.names,
    required this.totals,
    required this.taken,
    required this.plays,
    this.toPlay,
    this.winners = const [],
    this.keys,
    this.accounts,
  });

  final String table;
  final int target;

  /// How far into the game: the record's length when it was made. A
  /// view behind one already shown is old news.
  final int seq;

  final int hand;
  final Phase phase;

  /// What each seat is called: a person as they named themselves, a
  /// bot by its persona.
  final List<String> names;

  final List<int> totals;

  /// Points each seat has taken this hand so far.
  final List<int> taken;

  /// This hand's cards in the order they were played.
  final List<({int seat, Card card})> plays;

  /// Whose card it is; null between tricks, hands, or once it is over.
  final int? toPlay;

  /// Once the game is over, who won it.
  final List<int> winners;

  /// The key of the device in each seat held in person, null for a
  /// bot's: whose reactions (reactions.dart) a watcher shows, and at
  /// which seat. Null from a player's device that does not say.
  final List<PublicKey?>? keys;

  /// The account in each seat held in person, null for a bot's: whom a
  /// watcher's device blocked, if anyone (app/lib/pictures.dart), is
  /// matched by these. Null from a player's device that does not say.
  final List<String?>? accounts;

  bool get over => phase == Phase.gameOver;

  /// What [client] shows anyone at its table now, with [names] by seat.
  factory WatchedTable.of(TableClient client, List<String> names) {
    final game = client.game;
    final plays = [
      for (final m in client.rules.moves)
        if (m.hand == game.handNumber && m.card != null) (seat: m.seat, card: m.card!),
    ];
    final spec = client.tableSpec!;
    return WatchedTable(
      table: spec.id,
      target: spec.target,
      seq: client.rules.log.length,
      hand: game.handNumber,
      phase: game.phase,
      names: names,
      totals: game.totals,
      taken: game.taken,
      plays: plays,
      toPlay: game.currentSeat,
      winners: game.phase == Phase.gameOver ? game.winners : const [],
      keys: [
        for (final h in client.holders)
          if (h is HumanSeat) h.key else null,
      ],
      accounts: [
        for (final h in client.holders)
          if (h is HumanSeat) h.account else null,
      ],
    );
  }

  /// The seats held in person, by their devices' keys: who may react.
  Map<PublicKey, int> get seated => {
        for (final (seat, key) in (keys ?? const <PublicKey?>[]).indexed)
          if (key != null) key: seat,
      };

  Map<String, Object?> toJson() => {
    'table': table,
    'target': target,
    'seq': seq,
    'hand': hand,
    'phase': phase.name,
    'names': names,
    'totals': totals,
    'taken': taken,
    'plays': [
      for (final p in plays) [p.seat, p.card.index],
    ],
    if (toPlay != null) 'toPlay': toPlay,
    if (winners.isNotEmpty) 'winners': winners,
    if (keys != null) 'keys': keys,
    if (accounts != null) 'accounts': accounts,
  };

  /// [json] as a view of [table], or null for anything else.
  static WatchedTable? parse(Object? json, {required String table}) {
    try {
      final m = json as Map;
      if (m['table'] != table) return null;
      List<int> seats(Object? l, {int most = 1 << 20}) {
        final out = [for (final x in l as List) x as int];
        if (out.length != seatCount || out.any((x) => x < 0 || x > most)) throw const FormatException('seats');
        return out;
      }

      // At most sixty characters, as the app keeps a name
      // (app/lib/identity.dart, longestName), counted in code points
      // rather than UTF-16 units, so a name of emoji counts the same as
      // one of letters.
      final names = [for (final n in m['names'] as List) n as String];
      if (names.length != seatCount || names.any((n) => n.runes.length > 60)) return null;
      final plays = <({int seat, Card card})>[];
      for (final p in m['plays'] as List) {
        final pair = p as List;
        final seat = pair[0] as int;
        final card = pair[1] as int;
        if (seat < 0 || seat >= seatCount || card < 0 || card >= 52) return null;
        plays.add((seat: seat, card: Card.deck[card]));
      }
      if (plays.length > 52) return null;
      final toPlay = m['toPlay'] as int?;
      if (toPlay != null && (toPlay < 0 || toPlay >= seatCount)) return null;
      final winners = [for (final w in m['winners'] as List? ?? const []) w as int];
      if (winners.any((w) => w < 0 || w >= seatCount)) return null;
      final keys = m['keys'] == null ? null : [for (final k in m['keys'] as List) k as String?];
      if (keys != null && (keys.length != seatCount || keys.any((k) => k != null && !_key.hasMatch(k)))) return null;
      final accounts = m['accounts'] == null ? null : [for (final a in m['accounts'] as List) a as String?];
      if (accounts != null && (accounts.length != seatCount || accounts.any((a) => a != null && !_account.hasMatch(a)))) return null;
      return WatchedTable(
        table: table,
        target: m['target'] as int,
        seq: m['seq'] as int,
        hand: m['hand'] as int,
        phase: Phase.values.byName(m['phase'] as String),
        names: [for (final n in names) cleanName(n)],
        totals: seats(m['totals']),
        taken: seats(m['taken'], most: 26),
        plays: plays,
        toPlay: toPlay,
        winners: winners,
        keys: keys,
        accounts: accounts,
      );
    } catch (_) {
      return null;
    }
  }

  static final _key = RegExp(r'^[0-9a-f]{64}$');

  /// An account, or a device's key where no account names one.
  static final _account = RegExp(r'^[0-9a-f]{32}([0-9a-f]{32})?$');
}

/// A seated player's side of watching: answers whoever says they are
/// watching with the table's [WatchedTable], and goes on doing so after
/// every move for as long as someone has said so within [watchedFor].
///
/// One player answers, not all of them: the one with the lowest key of
/// those seated in person and heard from lately ([answers]), so that
/// one leaving hands the job to the next without a word between them.
class WatchBroadcast {
  WatchBroadcast({
    required Stream<({PublicKey from, Map<String, Object?> content})> heard,
    required this.say,
    required this.view,
    required this.answering,
    this.seated = const {},
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _sub = heard.listen((m) {
      if (m.content['watching'] != true || !admits(m.from, m.content)) return;
      final at = _now();
      _watchedAt = at;
      // Someone new gets the table now, not at the next move — however
      // many are watching, at most once in [_answerGap].
      if (at - _answeredAt < _answerGap) return;
      _answeredAt = at;
      _send(force: true);
    });
  }

  /// How long one "watching" keeps the views coming. A watcher says it
  /// again every [WatchBroadcast.again].
  static const watchedFor = Duration(seconds: 60);
  static const again = Duration(seconds: 20);

  final void Function(Map<String, Object?> content) say;
  final WatchedTable Function() view;

  /// Whether this device is the one to answer now ([answers]).
  final bool Function() answering;

  /// The accounts at the table: none of them is answered as a watcher.
  final Set<String> seated;

  /// Whether a watcher keyed [from] saying [content] is one to answer:
  /// licensed for that key where accounts are checked, and not of an
  /// account seated here.
  bool admits(PublicKey from, Map<String, Object?> content) {
    final licence = Licence.parse(content['licence']);
    if (!licenceFits(licence, from, at: DateTime.now())) return false;
    return !seated.contains(licence?.account ?? from) && !seated.contains(from);
  }

  final int Function() _now;
  late final StreamSubscription<void> _sub;
  int? _watchedAt;
  int _answeredAt = -_answerGap;
  String? _sent;
  static const _answerGap = 2000;

  bool get watched => _watchedAt != null && _now() - _watchedAt! < watchedFor.inMilliseconds;

  /// The table moved: the view again, if anyone is watching and it is
  /// this device's to say.
  void changed() => _send();

  void _send({bool force = false}) {
    if (!watched || !answering()) return;
    final v = view().toJson();
    final key = '${v['seq']} ${v['phase']} ${v['hand']}';
    if (!force && key == _sent) return;
    _sent = key;
    say({'view': v});
  }

  void close() => _sub.cancel();

  /// Whether [me] is the one to answer watchers at [client]'s table: of
  /// the seats still held in person, the lowest key among those whose
  /// line to the referee is open.
  static bool answers(TableClient client, PublicKey me) {
    final down = client.rules.down;
    final seated = [
      for (final h in client.holders)
        if (h is HumanSeat && (h.key == me || !down.containsKey(h.key))) h.key,
    ]..sort();
    return seated.isNotEmpty && seated.first == me;
  }
}
