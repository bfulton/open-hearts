// What a deployed build of the app is built with, as
// --dart-define-from-file, written to the path given:
//
//   node app/tool/defines.mjs <out.json>            production's: build_phone.sh, the iOS workflow, and deploy.sh on main
//   node app/tool/defines.mjs <out.json> preview    a preview's: deploy.sh for any other label
//
// The keys, origins and sign-in IDs come from config/openhearts.json and
// nothing else (service/functions/deployment.mjs, appDefines); a
// preview's have the keys previews have (configFor) and the preview
// relay to play on. Then the build's identity (app/lib/build_info.dart):
// the short commit, with "+" for a tree with uncommitted changes, and
// the UTC date. OH_UPDATE_CHECK turns on the "new build is up" pill,
// which only a deployed build has; on a phone it never shows, since a
// phone has no build-info.json to compare with. Local runs, tests and CI
// don't use this file, so they keep the defaults: "dev", no date, no
// pill.
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';

import { relayHost } from '../../ops/env.mjs';
import { appDefines, configFor } from '../../service/functions/deployment.mjs';

const [out, deployment = 'production'] = process.argv.slice(2);
if (!out || !['production', 'preview'].includes(deployment)) throw new Error('usage: node app/tool/defines.mjs <out.json> [preview]');
const config = JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));
const defines = appDefines(configFor(config, deployment));
if (deployment === 'preview') {
  defines.OH_RELAYS = `wss://${await relayHost('preview')}/{tag}`;
} else {
  if (!/^[0-9a-f]{64}$/.test(defines.OH_SERVICE_KEY ?? '')) throw new Error('config/openhearts.json has no serviceKey: a build without it has live play shut');
  if (!/^[0-9a-f]{64}$/.test(defines.OH_HOUSE_KEY ?? '')) throw new Error('config/openhearts.json has no houseKey: a build without it seats nobody live (./oh house key --apply)');
  if (!/^https:\/\/[^/]+$/.test(defines.OH_APP_ORIGIN ?? '')) throw new Error('config/openhearts.json has no appOrigin: a build without it asks no service and shares no link that opens');
}

const git = (...args) => execFileSync('git', args, { cwd: new URL('../..', import.meta.url), encoding: 'utf8' }).trim();
const dirty = git('status', '--porcelain') !== '';
defines.OH_BUILD_TAG = `${git('rev-parse', '--short', 'HEAD')}${dirty ? '+' : ''}`;
defines.OH_BUILD_DATE = new Date().toISOString().slice(0, 10);
defines.OH_UPDATE_CHECK = 'true';

await writeFile(out, `${JSON.stringify(defines, null, 2)}\n`);
