/// A player's icon, as they chose it (avatar.dart) — their picture, or
/// an icon on a colour — or, with nothing chosen, their initials on a
/// colour derived from who they are: a person's key, a bot's name. The
/// same player looks the same on every badge, list and sheet, on
/// every screen at the table.
library;

import 'package:flutter/material.dart';

import '../avatar.dart';
import '../l10n/l10n.dart';
import '../table_model.dart' show SeatLook;
import '../theme.dart';

class PlayerIcon extends StatelessWidget {
  const PlayerIcon({super.key, required this.name, required this.seed, this.avatar, this.size = 20});

  /// Whose: the initials come from it.
  final String name;

  /// What the derived colour comes from: a key, a persona's name,
  /// anything stable for the player.
  final String seed;

  /// What they chose, if anything.
  final Avatar? avatar;

  final double size;

  /// Up to two initials: "Mumtaz Mahal" is MM, "Westley" W, "You" Y.
  static String initialsOf(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    final letters = [for (final w in words.take(2)) w[0].toUpperCase()];
    return letters.join();
  }

  /// Ten colours that read on the felt and apart from each other.
  static const palette = [
    Color(0xFFE8776A), // coral
    Color(0xFFE4B363), // amber
    Color(0xFF7FB8E6), // sky
    Color(0xFFB79CE0), // lilac
    Color(0xFF7ED3B2), // mint
    Color(0xFFE79AC0), // rose
    Color(0xFF5FC4C9), // teal
    Color(0xFFD9C89A), // sand
    Color(0xFF9DA9E8), // periwinkle
    Color(0xFFB7C86A), // olive
  ];

  /// The colour for [seed]: an FNV-1a hash into the palette.
  static Color colorOf(String seed) {
    var h = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return palette[h % palette.length];
  }

  /// The colour shown: the chosen one, else the derived one.
  Color get color {
    final chosen = avatar?.color;
    return chosen != null && chosen >= 0 && chosen < palette.length ? palette[chosen] : colorOf(seed);
  }

  @override
  Widget build(BuildContext context) {
    final a = avatar;
    final picture = a?.picture;
    final Widget face;
    if (picture != null) {
      face = ClipOval(
        // Decoded no bigger than a picture the app makes (Avatar.side
        // square), whatever size another device's JPEG says it is: a
        // few kilobytes can declare a picture that takes gigabytes
        // decoded in full. One the app made is left as it is.
        child: Image(
          image: ResizeImage(MemoryImage(picture), width: Avatar.side, height: Avatar.side, policy: ResizeImagePolicy.fit),
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // A picture that will not decode is no picture: the icon or
          // the initials show instead.
          errorBuilder: (_, _, _) => _disc(),
        ),
      );
    } else {
      face = _disc();
    }
    return ExcludeSemantics(child: SizedBox(width: size, height: size, child: face));
  }

  Widget _disc() {
    final icon = avatar?.icon;
    final glyph = icon == null ? null : AvatarIcons.all[icon];
    final initials = initialsOf(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: glyph != null
          ? Icon(glyph, size: size * 0.62, color: Felt.dark)
          : Text(
              initials,
              // The initials are the icon's picture, drawn to fill its
              // disc as a glyph would: the disc is what a badge or a
              // sheet sizes, and the reader's type is in the name
              // beside it.
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: size * (initials.length > 1 ? 0.42 : 0.52),
                height: 1,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: Felt.dark,
              ),
            ),
    );
  }
}

/// A seat's icon as the table draws it, on the felt and on the score
/// sheets: the player's icon, with a bot's mark where a bot plays it.
class SeatIcon extends StatelessWidget {
  const SeatIcon({super.key, required this.look, required this.size});

  final SeatLook look;
  final double size;

  @override
  Widget build(BuildContext context) {
    final face = PlayerIcon(name: look.iconName, seed: look.seed, avatar: look.avatar, size: size);
    return look.bot ? BotMark(size: size, child: face) : face;
  }
}

/// A bot's icon, marked as one: a small robot at the icon's lower
/// right, over its edge only a little, so the face or the picture stays
/// whole. Touched, it says what it means. It is the icon's size
/// whatever the reader's text size, and a screen reader is told in
/// words instead (ui/table_view.dart).
class BotMark extends StatelessWidget {
  const BotMark({super.key, required this.size, required this.child});

  /// The icon's size, which the mark is in proportion to.
  final double size;

  /// The icon.
  final Widget child;

  /// A finger's room round the mark, which is too small to aim at.
  static const _reach = 28.0;

  @override
  Widget build(BuildContext context) {
    final mark = (size * 0.4).clamp(11.0, 16.0);
    // On the diagonal, its centre half its radius past the icon's rim:
    // a quarter of it over the icon, the rest beside it.
    final centre = size / 2 + (size / 2 + mark / 4) * 0.7071;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: child),
          Positioned(
            left: centre - _reach / 2,
            top: centre - _reach / 2,
            width: _reach,
            height: _reach,
            child: Tooltip(
              message: context.l10n.botTag,
              triggerMode: TooltipTriggerMode.tap,
              // The felt's own, solid: it is read over cards.
              decoration: BoxDecoration(
                color: Felt.dark,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Palette.chrome.withValues(alpha: 0.85)),
              ),
              textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.chrome),
              child: Center(
                child: Container(
                  width: mark,
                  height: mark,
                  decoration: BoxDecoration(
                    color: Felt.dark,
                    shape: BoxShape.circle,
                    border: Border.all(color: Palette.chrome.withValues(alpha: 0.85)),
                  ),
                  child: Icon(Icons.smart_toy, size: mark * 0.64, color: Palette.chrome),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
