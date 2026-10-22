// A report to NCMEC's CyberTipline, through its reporting API
// (https://report.cybertip.org/ispws/documentation/): the report opened
// with what happened and who did it, the picture uploaded and described,
// and the report finished, after which nothing can be added to it or
// taken back. Filed by service/do/known.mjs when Arachnid Shield
// matches a picture an account set (docs/how-to/handle-abuse-material.md).
//
// The service's answers are XML, a few known elements deep, so they are
// read by element name; Workers have no XML parser.

/// What NCMEC's API calls the incident, of the types it takes.
export const INCIDENT_TYPE = 'Child Pornography (possession, manufacture, and distribution)';

/// What the report names the game as.
const GAME = 'Open Hearts';

/// NCMEC refusing a call, or not answering one: which, and what it said.
export class NcmecRefused extends Error {
  constructor(path, status, code, said) {
    super(`NCMEC ${path}: ${status}${code !== null ? `, response code ${code}` : ''}${said ? `: ${said}` : ''}`);
    this.code = code;
  }
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);

/// <name>text</name>, or nothing for no text.
const el = (name, text) => (text === null || text === undefined || text === '' ? '' : `<${name}>${escape(text)}</${name}>`);

/// The text of the first <name> in [xml], or null.
export const elementOf = (xml, name) => new RegExp(`<${name}>([^<]*)</${name}>`).exec(xml ?? '')?.[1] ?? null;

const schema = 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="https://report.cybertip.org/ispws/xsd"';

/// The report, as /submit takes it: the picture an account set at
/// [at] (ISO, in the past), the reporter as [reporter] names them
/// ({firstName, lastName, email}), and the account by its number, the
/// name it played under ([name], or none), the device that put the
/// picture out ([device]), how it was found ([found], a sentence: by
/// Arachnid Shield unless said) and what was done ([done], a sentence).
export function reportXml({ at, reporter, account, name = null, device = null, found = "Matched by its PDQ hash against known images by the Canadian Centre for Child Protection's Arachnid Shield as it was set as a profile picture.", done }) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<report ${schema}>`,
    '<incidentSummary>',
    el('incidentType', INCIDENT_TYPE),
    el('incidentDateTime', at),
    '</incidentSummary>',
    '<internetDetails><onlineGamingIncident>',
    el('gameName', GAME),
    el('content', 'A profile picture, shown beside a player\'s name in pools, rooms and at tables in live play.'),
    el('additionalInfo', `${found} ${done}`),
    '</onlineGamingIncident></internetDetails>',
    '<reporter><reportingPerson>',
    el('firstName', reporter.firstName),
    el('lastName', reporter.lastName),
    el('email', reporter.email),
    '</reportingPerson></reporter>',
    '<personOrUserReported>',
    el('espIdentifier', account),
    el('espService', GAME),
    el('screenName', name),
    el('additionalInfo', device ? `The picture was set by the device whose public key is ${device}, in a request signed with it.` : null),
    '</personOrUserReported>',
    '</report>',
  ].join('');
}

/// The picture's details, as /fileinfo takes them: [fileName], set
/// at [at], its SHA-256 [digest], whether players were shown it
/// ([shown]), and whether anybody at Open Hearts looked at it
/// ([viewed]: the operator, for a picture they reported).
export function fileDetailsXml({ reportId, fileId, fileName, at, digest, shown, viewed = false }) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<fileDetails ${schema}>`,
    el('reportId', reportId),
    el('fileId', fileId),
    el('originalFileName', fileName),
    el('uploadedToEspTimestamp', at),
    el('fileViewedByEsp', viewed ? 'true' : 'false'),
    el('publiclyAvailable', shown ? 'true' : 'false'),
    `<details><nameValuePair type="HASH">${el('name', 'SHA-256')}${el('value', digest)}</nameValuePair></details>`,
    el('additionalInfo', shown ? 'Shown to other players before the match was known, then withheld.' : 'Withheld before any other player was shown it.'),
    '</fileDetails>',
  ].join('');
}

/// [report] filed at [endpoint] with [jpeg] as its file, named
/// [fileName] and described by [details] (reportId, fileId -> XML):
/// resolves the report's number once it is finished. A report that
/// fails before then is taken back, and NcmecRefused thrown, so that
/// asking again files one report, not two.
export async function fileReport({ endpoint, username, password, report, jpeg, fileName, details, fetchImpl = fetch }) {
  const auth = `Basic ${btoa(`${username}:${password}`)}`;
  const call = async (path, body, type = null) => {
    let res;
    try {
      res = await fetchImpl(`${endpoint}${path}`, { method: 'POST', headers: { authorization: auth, ...(type ? { 'content-type': type } : {}) }, body });
    } catch (e) {
      throw new NcmecRefused(path, `not reached (${e?.message ?? e})`, null, null);
    }
    const text = await res.text();
    const code = elementOf(text, 'responseCode');
    if (!res.ok || code !== '0') throw new NcmecRefused(path, res.status, code, elementOf(text, 'responseDescription'));
    return text;
  };
  const form = (fields) => {
    const f = new FormData();
    for (const [k, v] of Object.entries(fields)) f.set(k, ...v);
    return f;
  };
  const xml = 'text/xml; charset=utf-8';
  const reportId = elementOf(await call('/submit', report, xml), 'reportId');
  if (!reportId) throw new NcmecRefused('/submit', 200, '0', 'no report id');
  try {
    const fileId = elementOf(await call('/upload', form({ id: [reportId], file: [new Blob([jpeg], { type: 'image/jpeg' }), fileName] })), 'fileId');
    if (!fileId) throw new NcmecRefused('/upload', 200, '0', 'no file id');
    await call('/fileinfo', details(reportId, fileId), xml);
    await call('/finish', form({ id: [reportId] }));
  } catch (e) {
    await call('/retract', form({ id: [reportId] })).catch(() => {});
    throw e;
  }
  return reportId;
}
