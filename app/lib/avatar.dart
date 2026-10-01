/// What a player looks like: one of a set of icons on a colour of
/// their choosing, a small picture of their own, or — with nothing
/// chosen — their initials on a colour that is theirs. Chosen once in
/// the lobby, kept on the device with the name, and carried to the
/// others over the relay with the name (docs/04-live-play.md).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class Avatar {
  const Avatar({this.icon, this.color, this.picture});

  static const none = Avatar();

  /// One of [AvatarIcons.all], by its key; null for none.
  final String? icon;

  /// An index into the palette (ui/player_icon.dart); null for the
  /// colour derived from who the player is.
  final int? color;

  /// A picture of their own: a JPEG, [side] pixels square, a few
  /// kilobytes. Shown over any icon.
  final Uint8List? picture;

  /// The side of a picture, in pixels: enough for a badge, small
  /// enough to ride a relay.
  static const side = 64;

  /// The most a picture may be, in bytes: what a public relay carries
  /// without complaint.
  static const maxPictureBytes = 12000;

  bool get isDefault => icon == null && color == null && picture == null;

  Avatar copyWith({String? icon, int? color, Uint8List? picture, bool clearIcon = false, bool clearColor = false, bool clearPicture = false}) =>
      Avatar(
        icon: clearIcon ? null : icon ?? this.icon,
        color: clearColor ? null : color ?? this.color,
        picture: clearPicture ? null : picture ?? this.picture,
      );

  /// For the wire and the device. The picture is heavy, so a beat
  /// leaves it out and it travels on its own.
  Map<String, Object?> toJson({bool withPicture = true}) => {
        if (icon != null) 'icon': icon,
        if (color != null) 'color': color,
        if (withPicture && picture != null) 'picture': base64Encode(picture!),
      };

  static Avatar fromJson(Object? raw) {
    if (raw is! Map) return none;
    final icon = raw['icon'];
    final color = raw['color'];
    final picture = raw['picture'];
    Uint8List? bytes;
    if (picture is String && picture.isNotEmpty) {
      try {
        bytes = base64Decode(picture);
        if (bytes.length > maxPictureBytes) bytes = null;
      } catch (_) {
        bytes = null;
      }
    }
    return Avatar(
      icon: icon is String && AvatarIcons.all.containsKey(icon) ? icon : null,
      color: color is int && color >= 0 && color < AvatarIcons.paletteSize ? color : null,
      picture: bytes,
    );
  }

  /// A bot's: an icon and a colour from its name, the same at every
  /// table, so Westley is always Westley.
  static Avatar forBot(String name) {
    final h = _hash(name);
    final icons = AvatarIcons.all.keys.toList();
    return Avatar(icon: icons[h % icons.length], color: (h ~/ icons.length) % AvatarIcons.paletteSize);
  }

  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  @override
  bool operator ==(Object other) =>
      other is Avatar &&
      other.icon == icon &&
      other.color == color &&
      ((other.picture == null && picture == null) || (other.picture != null && picture != null && _same(other.picture!, picture!)));

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(icon, color, picture?.length);
}

/// The set to pick from: a key for the wire, a glyph for the screen.
/// Material's, since they are in the font already and read at twenty
/// pixels on a felt-green badge.
abstract final class AvatarIcons {
  static const all = <String, IconData>{
    'pets': Icons.pets,
    'rabbit': Icons.cruelty_free,
    'bug': Icons.bug_report,
    'sailing': Icons.sailing,
    'rocket': Icons.rocket_launch,
    'anchor': Icons.anchor,
    'castle': Icons.castle,
    'diamond': Icons.diamond,
    'spa': Icons.spa,
    'park': Icons.park,
    'star': Icons.star,
    'bolt': Icons.bolt,
    'sun': Icons.wb_sunny,
    'moon': Icons.nightlight_round,
    'flower': Icons.local_florist,
    'cake': Icons.cake,
    'coffee': Icons.coffee,
    'music': Icons.music_note,
    'game': Icons.sports_esports,
    'umbrella': Icons.umbrella,
    'bike': Icons.pedal_bike,
    'piano': Icons.piano,
    'palette': Icons.palette,
    'snow': Icons.ac_unit,
  };

  /// How many colours the palette has (ui/player_icon.dart).
  static const paletteSize = 10;
}
