// What a tag's object keeps to itself: a picture the operator took off
// an account (service/functions/pictures.mjs). The list is the one row
// every object reads, at most once a [SCREEN_EVERY_MS] and only when a
// picture comes its way, so an object that has pictures in it has the
// operator's word within a minute of the store having it. Apart from
// worker.mjs so it can be tested without the runtime.

import { WITHHELD_WHY, pictureDigest, pictureIn, withheldOf } from '../functions/pictures.mjs';
import { lobbyKind } from './relay.mjs';

/// How long an object goes by the list it last read.
export const SCREEN_EVERY_MS = 60 * 1000;

/// The most pictures' digests remembered, by event id, so that each is
/// worked out once.
const rememberedDigests = 5000;

/// The screen a tag's object puts before its relay (relay.mjs,
/// createRelay's `withhold`). [read] answers the list's row, or a
/// promise of it, or null for none; a read that fails leaves the last
/// list standing until the next.
export function pictureScreen({ read, now = Date.now, everyMs = SCREEN_EVERY_MS }) {
  let withheld = new Set();
  let readAt = -Infinity;
  let reading = null;
  const digests = new Map();

  /// The list, read again when the one in hand is [everyMs] old; one
  /// read at a time, whoever asks meanwhile waiting on it.
  async function current() {
    if (now() - readAt < everyMs) return withheld;
    reading ??= (async () => {
      try {
        withheld = withheldOf(await read(), now());
      } catch {
        // The store out of reach: the last list stands.
      }
      readAt = now();
    })().finally(() => {
      reading = null;
    });
    await reading;
    return withheld;
  }

  return {
    /// Why [event] is kept back, or null: a picture on the list.
    async withheld(event) {
      if (event?.kind !== lobbyKind) return null;
      const jpeg = pictureIn(event.content);
      if (!jpeg) return null;
      const list = await current();
      if (!list.size) return null;
      let digest = digests.get(event.id);
      if (digest === undefined) {
        digest = await pictureDigest(jpeg);
        if (digests.size >= rememberedDigests) digests.clear();
        digests.set(event.id, digest);
      }
      return digest !== null && list.has(digest) ? WITHHELD_WHY : null;
    },
  };
}
