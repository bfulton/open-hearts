// The account's profile. The name the others see and how they see it
// — an icon, a colour, a picture — are the account's, as the seat and
// the rating are: every device of the account shows the same, and a
// change on one reaches the others (docs/explanation/service.md). So the
// service keeps one profile per account, beside its devices, with a
// version that goes up by one at each write. The last write is the
// profile: there is nothing to merge in a name, and a person changes
// their own name from one device at a time.
//
// Read by any device of the account while its subscription stands;
// written only by the account's device in use, which is the one the
// person has in their hand. Strictly what the app makes and nothing
// else: a name of at most sixty characters (what a watched table
// carries, packages/table/lib/src/watch.dart), an icon and a colour from
// the app's own sets, and a picture as the app makes one — a JPEG of at
// most 12,000 bytes, base64 (app/lib/avatar.dart; a test holds the two
// sides equal). The picture is published at tables anyway; here it is
// kept with the account, for its devices, until the account's data is
// deleted. Where the account's turn runs in the relay worker, each new
// picture is checked as it is set, and kept apart as one of the
// account's pictures (service/do/profile_pictures.mjs): one that
// matches a known image of child sexual abuse is not kept, and the
// profile is saved without it. A name the filter refuses (names.mjs) is
// not kept: the others would see it.

import { entitlementOf } from './accounts.mjs';
import { nameRefused } from './names.mjs';
import { isAccount } from './rows.mjs';

/// The icons the app offers, by their keys (AvatarIcons.all).
export const PROFILE_ICONS = Object.freeze([
  'pets', 'rabbit', 'bug', 'sailing', 'rocket', 'anchor', 'castle', 'diamond', 'spa', 'park', 'star', 'bolt',
  'sun', 'moon', 'flower', 'cake', 'coffee', 'music', 'game', 'umbrella', 'bike', 'piano', 'palette', 'snow',
]);

/// How many colours the palette has (AvatarIcons.paletteSize).
export const PROFILE_COLOURS = 10;

/// The longest name, in characters.
export const PROFILE_NAME_MOST = 60;

/// What the service says of a name the filter refuses (names.mjs),
/// which the app knows (net/account_profile.dart) and does not send
/// again.
export const NAME_REFUSED = 'not an allowed name';

/// The most a picture may be, in bytes (Avatar.maxPictureBytes).
export const PROFILE_PICTURE_MOST = 12000;

/// The most a profile's own text may be: the picture, base64, and room
/// for the rest.
const PROFILE_TEXT_MOST = Math.ceil(PROFILE_PICTURE_MOST / 3) * 4 + 1024;

/// The most a profile's request may be: the text, sent once as itself
/// inside the JSON around it (quotes escaped), and the signature.
export const MOST_PROFILE_BODY = 2 * PROFILE_TEXT_MOST + 2048;

/// [text], the profile as a device sent it, checked:
/// {profile: {name, icon, color, picture}} with null for what is not
/// chosen, or {error}.
export function profileOf(text) {
  if (typeof text !== 'string' || text.length > PROFILE_TEXT_MOST) return { error: 'not a profile' };
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return { error: 'not a profile' };
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'not a profile' };
  if (Object.keys(raw).some((k) => !['name', 'icon', 'color', 'picture'].includes(k))) return { error: 'not a profile' };
  const { name, icon = null, color = null, picture = null } = raw;
  // A name as the profile page keeps it: trimmed, no longer than a
  // table carries, and nothing in it that is not text.
  if (typeof name !== 'string' || name !== name.trim() || [...name].length > PROFILE_NAME_MOST || /\p{Cc}/u.test(name)) {
    return { error: 'not a name' };
  }
  if (nameRefused(name)) return { error: NAME_REFUSED };
  if (icon !== null && !PROFILE_ICONS.includes(icon)) return { error: 'not one of the icons' };
  if (color !== null && !(Number.isInteger(color) && color >= 0 && color < PROFILE_COLOURS)) return { error: 'not one of the colours' };
  if (picture !== null && !isPicture(picture)) return { error: 'not a picture' };
  return { profile: { name, icon, color, picture } };
}

/// Whether [picture] is one as the app makes one: base64 of a JPEG of
/// at most [PROFILE_PICTURE_MOST] bytes.
function isPicture(picture) {
  if (typeof picture !== 'string' || picture.length < 4 || picture.length % 4 !== 0) return false;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(picture)) return false;
  const bytes = (picture.length / 4) * 3 - (picture.endsWith('==') ? 2 : picture.endsWith('=') ? 1 : 0);
  if (bytes > PROFILE_PICTURE_MOST) return false;
  // A JPEG begins with its start-of-image marker and another marker.
  const head = atob(picture.slice(0, 4));
  return head.charCodeAt(0) === 0xff && head.charCodeAt(1) === 0xd8 && head.charCodeAt(2) === 0xff;
}

/// A profile as it is served: what is chosen, without the nulls, as the
/// app keeps one (Avatar.toJson), and its version.
const profileShown = (row) => ({
  profile: {
    name: row.name,
    ...(row.icon !== null ? { icon: row.icon } : {}),
    ...(row.color !== null ? { color: row.color } : {}),
    ...(row.picture !== null ? { picture: row.picture } : {}),
  },
  version: row.version,
  updated_at: row.updated_at,
});

/// The account [key] is a device of, while it is one and its
/// subscription stands; null otherwise.
async function profileAccount(store, key, now) {
  const held = await entitlementOf(store, key, { now });
  if (!held || !isAccount(held.account) || !(await store.get(`ACCOUNT#${held.account}`, `DEVICE#${key}`))) return null;
  return held.account;
}

/// The account's profile, for a device of it: {profile, version,
/// updated_at}, or {profile: null, version: 0} for an account with none
/// yet — one from before profiles were kept, whose first device to ask
/// sends its own.
export async function profileRead(op, store, { now = Date.now() } = {}) {
  const account = await profileAccount(store, op.key, now);
  if (!account) return { status: 402, body: { error: 'no subscription' } };
  const row = await store.get(`ACCOUNT#${account}`, 'PROFILE');
  return { status: 200, body: row ? profileShown(row) : { profile: null, version: 0 } };
}

/// The account's profile written by its device in use, in the account's
/// turn: the next version, whatever was there, with its picture as
/// [pictures] keeps it (profile_pictures.mjs, accountPictures), where it
/// is given.
export async function profileWritten(op, store, active, { now = Date.now(), pictures = null } = {}) {
  const account = await profileAccount(store, op.key, now);
  if (!account) return { status: 402, body: { error: 'no subscription' } };
  const checked = profileOf(op.profile);
  if (checked.error) return { status: 400, body: { error: checked.error } };
  // From the device in hand, and no other: a device that has stepped
  // back writes once it takes the account back.
  if ((await active.get(account))?.key !== op.key) {
    return { status: 409, body: { error: 'superseded: another device of this account is in use' } };
  }
  const was = await store.get(`ACCOUNT#${account}`, 'PROFILE');
  const picture = pictures ? await pictures.set({ account, key: op.key, picture: checked.profile.picture, prev: was?.picture ?? null }) : checked.profile.picture;
  const row = { ...checked.profile, picture, version: (was?.version ?? 0) + 1, updated_at: new Date(now).toISOString() };
  await store.put(`ACCOUNT#${account}`, 'PROFILE', row);
  return { status: 200, body: profileShown(row) };
}
