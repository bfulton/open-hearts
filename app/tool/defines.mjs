// The phone build's --dart-define-from-file, from config/openhearts.json
// (service/functions/deployment.mjs, appDefines), and the build's
// identity (app/lib/build_info.dart): the short commit, with "+" for a
// tree with uncommitted changes, and the UTC date, as deploy.sh gives the
// web build. Written to the path given. build_phone.sh and the iOS
// workflow run it.  node app/tool/defines.mjs <out.json>
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';

import { appDefines } from '../../service/functions/deployment.mjs';

const out = process.argv[2];
if (!out) throw new Error('usage: node app/tool/defines.mjs <out.json>');
const config = JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));
const defines = appDefines(config);
if (!/^[0-9a-f]{64}$/.test(defines.OH_SERVICE_KEY ?? '')) throw new Error('config/openhearts.json has no serviceKey: a phone build without it has live play shut');
if (!/^[0-9a-f]{64}$/.test(defines.OH_HOUSE_KEY ?? '')) throw new Error('config/openhearts.json has no houseKey: a phone build without it seats nobody live');
if (!/^https:\/\/[^/]+$/.test(defines.OH_APP_ORIGIN ?? '')) throw new Error('config/openhearts.json has no appOrigin: a phone build without it asks no service and shares no link that opens');

const git = (...args) => execFileSync('git', args, { cwd: new URL('../..', import.meta.url), encoding: 'utf8' }).trim();
const dirty = git('status', '--porcelain') !== '';
defines.OH_BUILD_TAG = `${git('rev-parse', '--short', 'HEAD')}${dirty ? '+' : ''}`;
defines.OH_BUILD_DATE = new Date().toISOString().slice(0, 10);

await writeFile(out, `${JSON.stringify(defines, null, 2)}\n`);
