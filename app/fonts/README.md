# Fonts

`ReactionEmoji.ttf` is the six emoji of the table's reactions (👍 😂 😮
😬 🙏 👋, `Reaction` in `packages/table/lib/src/reactions.dart`), cut
from Noto Color Emoji. The web build draws them in it
(`app/lib/ui/reactions.dart`); a phone draws its own system's emoji.

The web build's own font has no emoji. Without this one, Flutter's web
engine fetches the slice of Noto Color Emoji that holds them from
Google's font servers the first time one is drawn, and draws empty boxes
until it comes. With it, they come with the app, from the app's own
host, before the first frame, and with the rest of the app for a load
with no network.

It is the slice Flutter's engine itself fetches for them, so the web
draws the same glyphs as before: version 2.047, COLRv1 vector glyphs.

To make it again, or to add a seventh reaction's emoji, with
[fontTools](https://github.com/fonttools/fonttools) 4.55.3 and brotli:

```bash
curl -o slice9.woff2 https://fonts.gstatic.com/s/notocoloremoji/v32/Yq6P-KqIXTD0t4D9z1ESnKM3-HpFabsE4tq3luCC7p-aXxcn.9.woff2
pyftsubset slice9.woff2 \
  --unicodes=U+1F44D,U+1F602,U+1F62E,U+1F62C,U+1F64F,U+1F44B \
  --layout-features='*' --name-IDs='*' --name-languages='*' \
  --output-file=ReactionEmoji.ttf
```

and then the licence's statement written into its name table, where the
font carries it wherever it is served:

```python
from fontTools.ttLib import TTFont
f = TTFont('ReactionEmoji.ttf')
f['name'].setName('This Font Software is licensed under the SIL Open Font License, Version 1.1. This license is available with a FAQ at: https://openfontlicense.org', 13, 3, 1, 0x409)
f.save('ReactionEmoji.ttf')
```

A new emoji may be in another slice: the slices and the code points each
covers are in Flutter's `font_fallback_data.dart`. `reactions_test.dart`
fails while any reaction's emoji is missing from the font.

Noto Color Emoji is © Google, under the SIL Open Font License 1.1
(`OFL.txt`).
