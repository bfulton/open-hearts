/// A player's icon, as they chose it (avatar.dart) — their picture, or
/// an icon on a colour — or, with nothing chosen, their initials on a
/// colour derived from who they are: a person's key, a bot's name. The
/// same player looks the same on every badge, list and sheet, on
/// every screen at the table.
library;

import 'package:flutter/material.dart';

import '../avatar.dart';
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
        child: Image.memory(
          picture,
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
