/// Your profile: who you are here, and how you have done.
///
/// The name the others see and how you look to them — one of the icons
/// on one of the colours, a picture of your own, or your initials —
/// both kept on the device, and read off your badge by everyone else
/// (avatar.dart). Above them, what the games say: a rating from the
/// live ones, which are signed on the relays, and a line for each half
/// of the game (stats.dart).
///
/// A page rather than a sheet, because there is more here than a form:
/// a rating and a record are things to come and look at, and a sheet is
/// for answering a question and getting out of the way. Leaving keeps
/// what was changed, whichever way you leave — nothing on it is the
/// kind of edit anyone means to cancel.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:table/table.dart' show Pace, Tally;

import 'avatar.dart';
import 'entitlement.dart';
import 'identity.dart';
import 'l10n/l10n.dart';
import 'net/account_profile.dart';
import 'net/network.dart';
import 'net/relays.dart';
import 'net/standing.dart';
import 'pages.dart';
import 'record_store.dart';
import 'stats.dart';
import 'theme.dart';
import 'ui/photo_crop.dart';
import 'ui/player_icon.dart';

/// How big a picture is, or null when the bytes are not one.
Size? sizeOfPicture(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  return decoded == null ? null : Size(decoded.width.toDouble(), decoded.height.toDouble());
}

/// A picture as chosen, made small: the square [from] of it — the
/// middle one when nobody has said otherwise — scaled to [Avatar.side]
/// and encoded as a JPEG a few kilobytes long. Null when the bytes are
/// not a picture.
///
/// [from] is in the picture's own pixels, which is what a crop window
/// hands back (ui/photo_crop.dart).
Uint8List? shrinkPicture(Uint8List bytes, {Rect? from}) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null; // a decoder that chokes on it is one more way of not being a picture
  }
  if (decoded == null) return null;
  final square = from == null
      ? img.copyResizeCropSquare(decoded, size: Avatar.side, interpolation: img.Interpolation.average)
      : _cut(decoded, from);
  // Nothing the camera wrote goes with it: a crop and a resize carry a
  // photograph's EXIF across, where it was taken included, and the
  // picture is published to the relays for anyone to read.
  square.exif = img.ExifData();
  // Quality down until it fits a relay, which it does at the first
  // step for any photograph this size.
  for (final quality in const [82, 70, 55, 40]) {
    final out = Uint8List.fromList(img.encodeJpg(square, quality: quality));
    if (out.length <= Avatar.maxPictureBytes) return out;
  }
  return null;
}

/// The square [from] of [decoded], at [Avatar.side]. Held inside the
/// picture whatever it is asked for: a window that ran off the edge
/// would be a crash rather than a picture.
img.Image _cut(img.Image decoded, Rect from) {
  final side = from.width.round().clamp(1, min(decoded.width, decoded.height)).toInt();
  final x = from.left.round().clamp(0, decoded.width - side).toInt();
  final y = from.top.round().clamp(0, decoded.height - side).toInt();
  final cut = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
  return img.copyResize(cut, width: Avatar.side, height: Avatar.side, interpolation: img.Interpolation.average);
}

/// Who this device is to everyone else.
typedef Profile = ({String name, Avatar avatar});

/// Opens the profile over [context] (router.dart, `/profile`); resolves
/// to what it was left with. The page keeps it on the device itself, so
/// one opened by its address alone loses nothing.
Future<Profile?> showProfile(BuildContext context, {Stream<PlayerStats>? stats}) =>
    openPage<Profile>(context, AppPage.profile, extra: stats);

/// What the games say on this device: its own games, and the relays'
/// results when it is online — [standing] when the caller already holds
/// it, so they are not asked twice.
Stream<PlayerStats> statsOnThisDevice({Standing? standing, bool online = true}) async* {
  final signer = await Identity.signer();
  yield* playerStats(
    store: PrefsRecordStore(),
    signer: signer,
    standing: standing,
    relays: online && !deviceOffline() ? appRelays() : null,
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.current, this.seed, this.stats});

  /// Who this device is, and the key its colour comes from: the
  /// device's own, read off it, when null.
  final Profile? current;
  final String? seed;

  /// What the games say, as it comes: [statsOnThisDevice] when null.
  final Stream<PlayerStats>? stats;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late Avatar _avatar = widget.current?.avatar ?? Avatar.none;
  late final _name = TextEditingController(text: widget.current?.name ?? '');
  late String _seed = widget.seed ?? '';

  /// What the page opened with: left unchanged, nothing is kept, so a
  /// page that sat open while another device of the account changed the
  /// profile does not put the old one back.
  late Profile _opened;
  String? _note;
  bool _busy = false;

  /// What the games say. The device's own come back at once; the
  /// relays' follow, or do not.
  PlayerStats? _stats;
  StreamSubscription<PlayerStats>? _watching;

  @override
  void initState() {
    super.initState();
    _opened = (name: Identity.nameOf(_name.text), avatar: _avatar);
    _watch();
    if (widget.current == null) unawaited(_readDevice());
    AccountProfile.current.addListener(_reprofiled);
  }

  /// Another device of the account changed the profile while this page
  /// was open: shown here too, unless something has been changed here.
  void _reprofiled() {
    if ((name: Identity.nameOf(_name.text), avatar: _avatar) == _opened) unawaited(_readDevice());
  }

  /// Who this device is, when nobody said: opened by its address.
  Future<void> _readDevice() async {
    final name = await Identity.name();
    final avatar = await Identity.avatar();
    final signer = await Identity.signer();
    if (!mounted) return;
    setState(() {
      _name.text = name ?? '';
      _avatar = avatar;
      _opened = (name: Identity.nameOf(_name.text), avatar: avatar);
      // The account's colour, the one every table shows it in.
      _seed = widget.seed ?? Entitlement.current.licence?.account ?? signer.publicKey;
    });
  }

  @override
  void didUpdateWidget(ProfilePage old) {
    super.didUpdateWidget(old);
    if (!identical(old.stats, widget.stats)) _watch();
  }

  void _watch() {
    _watching?.cancel();
    _watching = (widget.stats ?? statsOnThisDevice()).listen(
      (s) {
        if (mounted) setState(() => _stats = s);
      },
      onError: (_) {},
      // A stream that ends without saying anything has said something:
      // there is nothing here rather than something still coming.
      onDone: () {
        if (mounted) setState(() => _stats ??= const PlayerStats());
      },
    );
  }

  @override
  void dispose() {
    _watching?.cancel();
    AccountProfile.current.removeListener(_reprofiled);
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      // Smaller from the picker than a phone's photograph, which is
      // megabytes, and bigger than the badge: what is asked for here is
      // what a crop has left to work with when it is zoomed right in.
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 90);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final size = sizeOfPicture(bytes);
      if (size == null) {
        if (mounted) setState(() => _note = context.l10n.notAPicture);
        return;
      }
      if (!mounted) return;
      // Which part of it is the picture is the player's to say, not the
      // middle square's (ui/photo_crop.dart).
      final area = await Navigator.of(context).push<Rect>(
        MaterialPageRoute<Rect>(builder: (_) => PhotoCrop(bytes: bytes, picture: size)),
      );
      if (area == null || !mounted) return;
      final small = shrinkPicture(bytes, from: area);
      if (small == null) {
        setState(() => _note = context.l10n.notAPicture);
        return;
      }
      setState(() => _avatar = _avatar.copyWith(picture: small));
    } catch (e) {
      if (mounted) setState(() => _note = context.l10n.couldNotOpen('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icons = AvatarIcons.all.keys.toList();
    return PopScope(
      // However this page is left — the arrow, the system's own back —
      // what is on it is what is kept.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done();
      },
      child: Scaffold(
        backgroundColor: Felt.dark,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Palette.chromeDim,
          title: Text(context.l10n.yourProfile, style: const TextStyle(fontSize: 16, color: Palette.chromeDim)),
          actions: [
            TextButton(
              onPressed: _done,
              style: TextButton.styleFrom(foregroundColor: Palette.gold),
              child: Text(context.l10n.done, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: SafeArea(child: _body(icons)),
      ),
    );
  }

  Widget _body(List<String> icons) {
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            // The keyboard comes up under the name: the page scrolls
            // over it rather than behind it.
            padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Who you are: the face, and the name under it.
                Center(
                  child: PlayerIcon(name: _shownName, seed: _seed, avatar: _avatar, size: 92),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.words,
                  decoration: _field(context.l10n.yourName),
                  // The badge above it wears the initials of what is
                  // being typed, so a name with no avatar behind it
                  // is still a picture of something.
                  onChanged: (_) => setState(() {}),
                  // No longer than a table carries, or the account keeps.
                  inputFormatters: [LengthLimitingTextInputFormatter(Identity.longestName)],
                  style: const TextStyle(color: Palette.chrome, fontSize: 16),
                ),
                const SizedBox(height: 20),
                _Record(stats: _stats),
                const SizedBox(height: 22),
                SectionHeading(context.l10n.howYouLook),
                const SizedBox(height: 12),
                // The icons: a grid, the chosen one ringed.
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final key in icons)
                      _Choice(
                        label: context.l10n.avatarIcon(key),
                        selected: _avatar.icon == key && _avatar.picture == null,
                        onTap: () => setState(() => _avatar = _avatar.copyWith(icon: key, clearPicture: true)),
                        color: PlayerIcon.palette[_avatar.color ?? _derivedIndex()],
                        child: Icon(AvatarIcons.all[key], size: 22, color: Felt.dark),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                // The colours.
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < PlayerIcon.palette.length; i++)
                      _Choice(
                        label: context.l10n.colourNumber(i + 1),
                        selected: (_avatar.color ?? _derivedIndex()) == i,
                        onTap: () => setState(() => _avatar = _avatar.copyWith(color: i)),
                        color: PlayerIcon.palette[i],
                        size: 36,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pickPhoto,
                        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                        label: Text(context.l10n.useAPhoto),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Palette.chrome,
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _avatar.isDefault ? null : () => setState(() => _avatar = Avatar.none),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Palette.chrome,
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(context.l10n.myInitials),
                      ),
                    ),
                  ],
                ),
                if (_note != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _note!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, color: Palette.danger),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Kept on the device, then closed with it: whoever opened the page
  /// reads it back from there (home_page.dart), so it is the same
  /// whether the menu opened it or an address did. A change goes on to
  /// the account's other devices too, behind the page
  /// (net/account_profile.dart).
  Future<void> _done() async {
    final chosen = (name: Identity.nameOf(_name.text), avatar: _avatar);
    if (chosen != _opened) {
      await AccountProfile.current.keep(chosen.name, chosen.avatar);
      unawaited(AccountProfile.current.sync());
    }
    if (mounted) Navigator.of(context).pop(chosen);
  }

  /// What the badge in the sheet wears while there is nothing to go on.
  String get _shownName => _name.text.trim().isEmpty ? '?' : _name.text.trim();

  int _derivedIndex() => PlayerIcon.palette.indexOf(PlayerIcon.colorOf(_seed));

  static InputDecoration _field(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Palette.chromeDim),
    isDense: true,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Palette.gold),
    ),
  );
}

/// A quiet label over a section.
/// How long you take over a card, and what it does.
///
/// Measured by this device from its own turns and kept on it: it is the
/// one number about a game no two peers can agree on, since the record
/// carries no clock (packages/table, pace.dart). Worth saying out loud
/// because it is stated in the pool and decides who you are seated
/// with, and nobody should have that said about them without being
/// told.
class _PaceLine extends StatelessWidget {
  const _PaceLine({required this.pace});

  final Pace pace;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.speed_outlined, size: 15, color: Palette.chromeDim),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            context.l10n.paceLine(pace),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, height: 1.4, color: Palette.chromeDim),
          ),
        ),
      ],
    );
  }
}

/// What the games say: the rating over the two halves of the game.
///
/// The rating is the live games' alone — they are the ones signed by
/// everyone at the table — so a device that has played none has no
/// rating to show, and says so rather than showing the 1500 everyone
/// starts at as though it had been earned.
class _Record extends StatelessWidget {
  const _Record({required this.stats});

  final PlayerStats? stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stats = this.stats;
    final rating = stats?.rating;
    final rated = (stats?.ratedGames ?? 0) > 0 && rating != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(l10n.rating),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            children: [
              Text(
                rated ? '${rating.shown}' : '—',
                // A rating is what you are, not something to press.
                style: TextStyle(fontSize: 38, fontWeight: FontWeight.w700, height: 1, color: rated ? Palette.chrome : Palette.chromeDim),
              ),
              const SizedBox(height: 7),
              Text(
                stats == null || stats.asking
                    ? l10n.countingGames
                    : !stats.reached
                    ? l10n.relaysSilent
                    : !rated
                    ? l10n.playRatedForRating
                    : rating.provisional
                    ? l10n.ratingProvisionalFrom(stats.ratedGames)
                    : l10n.ratingFrom(stats.ratedGames),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: Palette.chromeDim),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _PaceLine(pace: stats?.pace ?? Pace.fresh),
        const SizedBox(height: 18),
        SectionHeading(l10n.yourGames),
        const SizedBox(height: 10),
        _Games(live: stats?.live, alone: stats?.alone, liveMissing: stats != null && !stats.reached),
        if (stats != null && stats.history.recent.isNotEmpty) ...[
          const SizedBox(height: 22),
          SectionHeading(l10n.statsRecent(stats.history.recent.length)),
          const SizedBox(height: 10),
          _Lately(history: stats.history),
        ],
      ],
    );
  }
}

/// The games alone, lately: each one's final score as a column, oldest
/// on the left, with their average across them — and under it what the
/// queen and the moon did over every hand kept. One series, so no
/// legend; the numbers are said aloud in one line, which is the chart's
/// table for a screen reader.
class _Lately extends StatelessWidget {
  const _Lately({required this.history});

  final SoloHistory history;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final average = history.average!.round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: l10n.statsRecentSpoken(history.recent.length, history.recent.join(', '), average),
          child: ExcludeSemantics(
            child: SizedBox(height: 92, child: CustomPaint(painter: _ScoresPainter(history.recent, average: average, label: l10n.statsAverage(average)))),
          ),
        ),
        const SizedBox(height: 6),
        Text(l10n.statsLowerIsBetter, style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim)),
        const SizedBox(height: 14),
        Row(
          children: [
            _Tile(value: history.queens, label: l10n.statsQueens),
            const SizedBox(width: 8),
            _Tile(value: history.moonsShot, label: l10n.statsMoonsShot),
            const SizedBox(width: 8),
            _Tile(value: history.moonsBlocked, label: l10n.statsMoonsBlocked),
          ],
        ),
        const SizedBox(height: 6),
        Text(l10n.statsOverHands(history.hands), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, color: Palette.chromeDim)),
      ],
    );
  }
}

/// One number and what it counts.
class _Tile extends StatelessWidget {
  const _Tile({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            children: [
              Text('$value',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700, color: Palette.chrome, fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(height: 2),
              Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, height: 1.25, color: Palette.chromeDim)),
            ],
          ),
        ),
      );
}

/// The columns: thin, a gap of the ground between them, rounded at the
/// end away from the baseline; a hairline for the baseline; the average
/// a gold rule across them with its number above it, in the text's own
/// colour.
class _ScoresPainter extends CustomPainter {
  _ScoresPainter(this.scores, {required this.average, required this.label});

  final List<int> scores;
  final int average;
  final String label;

  static const _gap = 2.0;
  static const _labelRoom = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final top = scores.fold<int>(average, max).clamp(26, 1 << 20).toDouble();
    final plot = size.height - _labelRoom;
    double y(num v) => size.height - v / top * plot;
    // Never wider than a column in a full chart, so a short history does
    // not draw a few slabs.
    final step = size.width / SoloHistory.shown;
    final width = step - _gap;
    final bar = Paint()..color = Palette.chromeDim.withValues(alpha: 0.55);
    for (var i = 0; i < scores.length; i++) {
      final left = i * step + _gap / 2;
      final rect = Rect.fromLTRB(left, y(scores[i]), left + width, size.height);
      final r = Radius.circular(min(4, width / 2));
      canvas.drawRRect(RRect.fromRectAndCorners(rect, topLeft: r, topRight: r), bar);
    }
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.18)
          ..strokeWidth = 1);
    final at = y(average);
    canvas.drawLine(Offset(0, at), Offset(size.width, at),
        Paint()
          ..color = Palette.gold
          ..strokeWidth = 2);
    final text = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Palette.chrome)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    text.paint(canvas, Offset(size.width - text.width, max(0, at - text.height - 2)));
  }

  @override
  bool shouldRepaint(_ScoresPainter old) => old.average != average || old.label != label || !listEquals(old.scores, scores);
}

/// The two halves of the game side by side: what each line is, once,
/// down the left, and a column of numbers for each half, right-aligned
/// under its name so the figures line up. A half with no games in it
/// gets its column all the same, at nothing: an empty column says "not
/// yet" better than an absent one says anything.
class _Games extends StatelessWidget {
  const _Games({required this.live, required this.alone, this.liveMissing = false});

  final Tally? live;
  final Tally? alone;

  /// The relays did not answer, so the live half is unknown rather than
  /// empty.
  final bool liveMissing;

  static const _column = 76.0;
  static const _label = TextStyle(fontSize: 12.5, color: Palette.chromeDim);
  static const _title = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Palette.chrome);
  static const _number = TextStyle(
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    color: Palette.chrome,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String value(Tally? t, String Function(Tally t) of, {bool missing = false}) => t == null || missing ? '—' : of(t);
    TableRow line(String label, String Function(Tally t) of) => TableRow(children: [
          Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(label, style: _label)),
          Text(value(live, of, missing: liveMissing), textAlign: TextAlign.right, style: _number),
          Text(value(alone, of), textAlign: TextAlign.right, style: _number),
        ]);
    return Table(
      columnWidths: const {1: FixedColumnWidth(_column), 2: FixedColumnWidth(_column)},
      defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        TableRow(children: [
          const SizedBox.shrink(),
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l10n.gamesLive, textAlign: TextAlign.right, style: _title)),
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l10n.gamesAlone, textAlign: TextAlign.right, style: _title)),
        ]),
        line(l10n.gamesPlayed, (t) => '${t.games}'),
        line(l10n.gamesWon, (t) => '${t.won}'),
        line(l10n.gamesAverage, (t) => t.average?.round().toString() ?? '—'),
        // Low is good: the best game is the one you came out of with
        // the fewest.
        line(l10n.gamesBest, (t) => t.best?.toString() ?? '—'),
      ],
    );
  }
}

/// One thing to pick: a disc, ringed when it is the choice.
///
/// The ring is white, since which one you chose is what a thing is,
/// not something to do (docs/explanation/screens.md); and it stands off the
/// disc by a gap of felt, so it shows on every colour, amber included.
class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap, required this.color, this.child, this.size = 50});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
  final Widget? child;
  final double size;

  static const _ring = 2.0;
  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            width: size,
            height: size,
            // Inside the ring, which the decoration's border takes
            // its own width for.
            padding: const EdgeInsets.all(_gap),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? Palette.chrome : Colors.transparent, width: _ring),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
