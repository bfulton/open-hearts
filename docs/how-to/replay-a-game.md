# Replay a solo game or check a deal by hand

Use this guide to replay a solo game from its record, or to check a solo game's deal with nothing but Python's standard library.

A solo game's record holds the seed, the bots and your own passes and plays. Everything else is computed again from them. For the record's format and the generator, see [Solo games](../explanation/fair-deal.md#solo-games-where-the-randomness-comes-from).

## Before you begin

- For the replay, install Dart, and run `dart pub get` in `packages/engine/`.
- For the deal check, install Python 3.
- Run the commands from the repository root.

## Copy a game's record

1. Finish a solo game in the app.
1. On the game-over sheet, select **Copy record**. The record is on your clipboard, as one line that starts with `oh2:` (or `oh1:` for a game seeded by a small number).

## Replay the game

1. Replay the record, in single quotes so the shell leaves it as it is:

   ```bash
   (cd packages/engine && dart run tool/replay.dart 'oh2:…')
   ```

   The tool prints the seed and the players, then for each hand its scores, each seat's cards as dealt, your pass, and every trick with who won it. A hand where someone shot the moon is marked.

## Check a deal by hand

This works for `oh2:` records only. An `oh1:` record's seed is dealt by Dart's own `Random`.

1. Save this script as `deal.py`. It prints the cards dealt in one hand, one line a seat: you, then west, north and east.

   ```python
   import hashlib, hmac, struct, sys

   seed, hand = bytes.fromhex(sys.argv[1]), int(sys.argv[2])
   words = []
   for block in range(16):  # a deal needs seven blocks; sixteen is plenty
       mac = hmac.new(seed, b'deal' + struct.pack('>II', hand, block), hashlib.sha256)
       words += struct.unpack('>8I', mac.digest())
   deck = list(range(52))
   for i in range(51, 0, -1):
       n = i + 1
       while words[0] >= 2**32 - 2**32 % n:
           words.pop(0)
       j = words.pop(0) % n
       deck[i], deck[j] = deck[j], deck[i]
   cards = [r + s for s in 'CDSH' for r in '2 3 4 5 6 7 8 9 10 J Q K A'.split()]
   for seat in range(4):
       print(' '.join(cards[c] for c in sorted(deck[13 * seat:13 * seat + 13])))
   ```

1. Take the seed from the record: the 64 hex digits between the first and second colons.
1. Run the script with the seed and the hand's number. Hands count from 0:

   ```bash
   python3 deal.py 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f 0
   ```

## Check it worked

1. For the example seed above, the script prints the first hand that `packages/engine/test/deal_seed_test.dart` pins:

   ```text
   2C 3C 4C 6C 9C 10C KC 3D 6D AS 8H QH AH
   7C 2D 5D 7D JD 2S 3S 5S 6S QS KS 6H JH
   QC AC 4D QD 4S 8S 9S 10S JS 2H 3H 5H 7H
   5C 8C JC 8D 9D 10D KD AD 7S 4H 9H 10H KH
   ```

1. For your own record, the script's four lines for hand `h` are the four `dealt` lines that the replay prints under `hand h+1`.

## Learn more

- [The fair deal](../explanation/fair-deal.md#what-is-guaranteed-and-what-is-not): what a deal guarantees, solo and live.
