// The services a new picture can be checked with against known images
// of child sexual abuse (known.mjs): the Canadian Centre for Child
// Protection's Arachnid Shield, sent the picture's PDQ hash
// (arachnid.mjs), and Microsoft's PhotoDNA, sent its PhotoDNA Edge
// Hashes (photodna.mjs). Neither is ever sent the picture. One is in
// use at a time: Shield, unless the run-time row `config|known` names
// PhotoDNA, so that either can stand in for the other with one
// command, without a deploy (`oh config set known`,
// docs/how-to/handle-abuse-material.md). The one in use checks pictures
// once the deployment has what it needs. A picture either one cleared
// is clear, and either one's match is a match, whichever is in use.

import { CSAM, HARMFUL, MIN_QUALITY, TEST, pictureHash, shieldSays } from './arachnid.mjs';
import { photoDnaMatch } from './photodna.mjs';
import { storeOf } from '../functions/rows.mjs';

/// Each checker's id, as the run-time row names the one in use, as
/// what each said of a picture is kept (known.mjs), and as a copy names
/// the one that said what is known of it (profile_pictures.mjs,
/// `knownBy`).
export const SHIELD = 'shield';
export const PHOTODNA = 'photodna';

/// What each checker is called in the operator's email, and how a match
/// by it is told in a report to NCMEC (ncmec.mjs, reportXml).
export const CHECKERS = {
  [SHIELD]: { name: 'Arachnid Shield', found: "by its PDQ hash against known images by the Canadian Centre for Child Protection's Arachnid Shield" },
  [PHOTODNA]: { name: 'PhotoDNA', found: "by its PhotoDNA Edge Hashes against known images by Microsoft's PhotoDNA" },
};

/// The run-time row that says which checker is in use, {checker}
/// (ops/setup.mjs writes it), as knownSettingsOf reads it: the checker
/// it names, or Shield for anything else.
export const KNOWN_ROW = ['config', 'known'];
export const knownSettingsOf = (raw) => ({ checker: raw?.checker === PHOTODNA ? PHOTODNA : SHIELD });

/// The checker in use, as [env]'s store says (KNOWN_ROW): Shield too
/// when the row cannot be read.
export async function checkerIn(env) {
  try {
    return knownSettingsOf(await storeOf(env)?.get(...KNOWN_ROW)).checker;
  } catch {
    return SHIELD;
  }
}

/// [names] as a sentence lists them: "A", "A and B", "A, B and C".
export const listed = (names) => (names.length < 2 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`);

/// Whether [env] has any checker's credentials, so that a picture is
/// asked about at all, and anything the one in use lacks is told
/// (checkersOf, missing).
export const anyChecker = (env) => !!(env.OH_ARACHNID_USERNAME || env.OH_PHOTODNA_KEY);

/// The checker [checker] (an id) as [env] has it: {on, missing}. [on]
/// is it, once it has what it needs, as {id, name, ask}, where ask(jpeg,
/// digest) says of the JPEG [jpeg] (its bytes) 'match', 'harmful'
/// (Shield knows it as a harmful or abusive image of a child) or
/// 'clear', throws Unreadable (jpeg.mjs) for a picture it cannot hash,
/// and throws anything else when the service does not answer; [] until
/// then. [missing] says what it lacks, when it lacks anything but has
/// its credentials, or when another checker has credentials and it has
/// none. [pdq] makes a picture's PDQ hash (arachnid.mjs, pictureHash);
/// [edgeHasher] its PhotoDNA Edge Hashes, from the module the relay was
/// deployed with (photodna.mjs, jpegHasher), or null without it; [log]
/// is told of a match with either service's test pictures, which is no
/// match.
export function checkersOf(env, { checker = SHIELD, fetchImpl = fetch, pdq = pictureHash, edgeHasher = null, log = () => {} } = {}) {
  const on = [];
  const missing = [];
  if (checker === SHIELD) {
    const { OH_ARACHNID_ENDPOINT: endpoint, OH_ARACHNID_USERNAME: username, OH_ARACHNID_PASSWORD: password } = env;
    if (!username && env.OH_PHOTODNA_KEY) missing.push('Arachnid Shield is the checker in use, and OH_ARACHNID_USERNAME is not set, so no picture is checked; PhotoDNA has its key: `./oh config set known` (docs/how-to/handle-abuse-material.md)');
    else if (username && !password) missing.push('OH_ARACHNID_USERNAME is set but OH_ARACHNID_PASSWORD is not, so no picture is checked');
    else if (username && !endpoint) missing.push('OH_ARACHNID_USERNAME is set but arachnid.endpoint in config/openhearts.json is not, so no picture is checked');
    else if (username) {
      on.push({
        id: SHIELD,
        name: CHECKERS[SHIELD].name,
        async ask(jpeg, digest) {
          const { hash, quality } = pdq(jpeg);
          if (quality < MIN_QUALITY) {
            log(`known pictures: ${digest} is too featureless to match (quality ${quality}), and is not asked about`);
            return 'clear';
          }
          const said = await shieldSays(hash, { endpoint, username, password, fetchImpl });
          if (said === TEST) log(`known pictures: ${digest} matched Arachnid Shield's test pictures, and nobody is acted on for it`);
          return said === CSAM ? 'match' : said === HARMFUL ? 'harmful' : 'clear';
        },
      });
    }
  }
  if (checker === PHOTODNA) {
    const { OH_PHOTODNA_ENDPOINT: endpoint, OH_PHOTODNA_KEY: key } = env;
    if (!key && env.OH_ARACHNID_USERNAME) missing.push('PhotoDNA is the checker in use, and OH_PHOTODNA_KEY is not set, so no picture is checked; Arachnid Shield has its credentials: `./oh config set known` (docs/how-to/handle-abuse-material.md)');
    else if (key && !endpoint) missing.push('OH_PHOTODNA_KEY is set but photodna.endpoint in config/openhearts.json is not, so no picture is checked');
    else if (key && !edgeHasher) missing.push('OH_PHOTODNA_KEY is set but the relay was deployed without the PhotoDNA module, so no picture is checked (docs/how-to/update-the-photodna-module.md)');
    else if (key) {
      on.push({
        id: PHOTODNA,
        name: CHECKERS[PHOTODNA].name,
        async ask(jpeg, digest) {
          const { match, test } = await photoDnaMatch(jpeg, { endpoint, key, hasher: edgeHasher, fetchImpl });
          if (test && !match) log(`known pictures: ${digest} matched only Microsoft's test pictures, and nobody is acted on for it`);
          return match ? 'match' : 'clear';
        },
      });
    }
  }
  return { on, missing };
}

/// What the checkers' answers [by] ({id: said}) come to, [on] being the
/// ids of those in use now: 'match' when any matched the picture, else
/// 'harmful' when any knows it as harmful, else 'clear' when any cleared
/// it, whether or not it is in use now; else 'unreadable' when one in
/// use cannot hash it. Null while none of that is said, and one in use
/// is to be asked.
export function verdictOf(by, on) {
  const said = Object.values(by);
  for (const settled of ['match', 'harmful', 'clear']) if (said.includes(settled)) return settled;
  return on.some((id) => by[id] === 'unreadable') ? 'unreadable' : null;
}
