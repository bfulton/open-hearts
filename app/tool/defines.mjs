// The phone build's --dart-define-from-file, from config/openhearts.json
// (service/functions/deployment.mjs, appDefines), written to the path
// given. build_phone.sh runs it.  node app/tool/defines.mjs <out.json>
import { readFile, writeFile } from 'node:fs/promises';

import { appDefines } from '../../service/functions/deployment.mjs';

const out = process.argv[2];
if (!out) throw new Error('usage: node app/tool/defines.mjs <out.json>');
const config = JSON.parse(await readFile(new URL('../../config/openhearts.json', import.meta.url), 'utf8'));
const defines = appDefines(config);
if (!/^[0-9a-f]{64}$/.test(defines.OH_SERVICE_KEY ?? '')) throw new Error('config/openhearts.json has no serviceKey: a phone build without it has live play shut');
if (!/^https:\/\/[^/]+$/.test(defines.OH_APP_ORIGIN ?? '')) throw new Error('config/openhearts.json has no appOrigin: a phone build without it asks no service and shares no link that opens');
await writeFile(out, `${JSON.stringify(defines, null, 2)}\n`);
