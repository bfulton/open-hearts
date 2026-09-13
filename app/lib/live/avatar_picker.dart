/// Choosing how you look: one of the icons on one of the colours, a
/// picture of your own, or your initials. Saved on the device with the
/// name; the others see it on your badge (avatar.dart).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../avatar.dart';
import '../theme.dart';
import '../ui/player_icon.dart';

/// A picture as chosen, made small: the middle square of it, scaled to
/// [Avatar.side] and encoded as a JPEG a few kilobytes long. Null when
/// the bytes are not a picture.
Uint8List? shrinkPicture(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null; // a decoder that chokes on it is one more way of not being a picture
  }
  if (decoded == null) return null;
  final square = img.copyResizeCropSquare(decoded, size: Avatar.side, interpolation: img.Interpolation.average);
  // Quality down until it fits a relay, which it does at the first
  // step for any photograph this size.
  for (final quality in const [82, 70, 55, 40]) {
    final out = Uint8List.fromList(img.encodeJpg(square, quality: quality));
    if (out.length <= Avatar.maxPictureBytes) return out;
  }
  return null;
}

/// Opens the picker over [context]; resolves to the avatar chosen, or
/// null if the sheet was dismissed without a change.
Future<Avatar?> showAvatarPicker(BuildContext context, {required Avatar current, required String name, required String seed}) {
  return showModalBottomSheet<Avatar>(
    context: context,
    backgroundColor: Felt.mid,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _AvatarSheet(current: current, name: name, seed: seed),
  );
}

class _AvatarSheet extends StatefulWidget {
  const _AvatarSheet({required this.current, required this.name, required this.seed});

  final Avatar current;
  final String name;
  final String seed;

  @override
  State<_AvatarSheet> createState() => _AvatarSheetState();
}

class _AvatarSheetState extends State<_AvatarSheet> {
  late Avatar _avatar = widget.current;
  String? _note;
  bool _busy = false;

  Future<void> _pickPhoto() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      // Small from the picker where it can be: a phone's photo is
      // megabytes, and the shrink is in Dart.
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 256, maxHeight: 256, imageQuality: 85);
      if (picked == null) return;
      final small = shrinkPicture(await picked.readAsBytes());
      if (small == null) {
        setState(() => _note = 'That did not read as a picture.');
        return;
      }
      setState(() => _avatar = _avatar.copyWith(picture: small));
    } catch (e) {
      setState(() => _note = 'Could not open that: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icons = AvatarIcons.all.keys.toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PlayerIcon(name: widget.name, seed: widget.seed, avatar: _avatar, size: 48),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text('Your avatar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Palette.gold)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_avatar),
                  style: TextButton.styleFrom(foregroundColor: Palette.gold),
                  child: const Text('Done', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // The icons: a grid, the chosen one ringed.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final key in icons)
                  _Choice(
                    label: AvatarIcons.names[key]!,
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
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < PlayerIcon.palette.length; i++)
                  _Choice(
                    label: 'Colour ${i + 1}',
                    selected: (_avatar.color ?? _derivedIndex()) == i,
                    onTap: () => setState(() => _avatar = _avatar.copyWith(color: i)),
                    color: PlayerIcon.palette[i],
                    size: 30,
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
                    label: const Text('Use a photo'),
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
                    child: const Text('My initials'),
                  ),
                ),
              ],
            ),
            if (_note != null) ...[
              const SizedBox(height: 10),
              Text(_note!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: Palette.danger)),
            ],
          ],
        ),
      ),
    );
  }

  int _derivedIndex() => PlayerIcon.palette.indexOf(PlayerIcon.colorOf(widget.seed));
}

/// One thing to pick: a disc, ringed in gold when it is the choice.
class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap, required this.color, this.child, this.size = 44});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
  final Widget? child;
  final double size;

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
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: selected ? Palette.gold : Colors.transparent, width: 3),
              boxShadow: selected ? [BoxShadow(color: Palette.gold.withValues(alpha: 0.5), blurRadius: 10)] : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
