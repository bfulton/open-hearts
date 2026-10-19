// A report to NCMEC's CyberTipline (ncmec.mjs): the report and the
// picture's details as NCMEC's API takes them, filed in its order, and
// taken back when it fails part way.
//
//   node --test service/functions

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { INCIDENT_TYPE, NcmecRefused, elementOf, fileDetailsXml, fileReport, reportXml } from './ncmec.mjs';

const reporter = { firstName: 'Bright', lastName: 'Fulton', email: 'help@openhearts.game' };
const account = '0123456789abcdef0123456789abcdef';
const digest = 'ab'.repeat(32);
const at = '2026-10-19T20:00:00.000Z';

test('the report: what happened, who reports it and who did it, with what they wrote escaped', () => {
  const xml = reportXml({ at, reporter, account, name: 'Ada <&> "x"', device: 'cd'.repeat(32), done: 'The picture was withheld.' });
  assert.match(xml, /^<\?xml version="1.0" encoding="UTF-8"\?><report xmlns:xsi="http:\/\/www.w3.org\/2001\/XMLSchema-instance" xsi:noNamespaceSchemaLocation="https:\/\/report.cybertip.org\/ispws\/xsd">/);
  assert.equal(elementOf(xml, 'incidentType'), INCIDENT_TYPE);
  assert.equal(elementOf(xml, 'incidentDateTime'), at);
  assert.equal(elementOf(xml, 'gameName'), 'Open Hearts');
  assert.equal(elementOf(xml, 'email'), 'help@openhearts.game');
  assert.equal(elementOf(xml, 'espIdentifier'), account);
  assert.equal(elementOf(xml, 'screenName'), 'Ada &lt;&amp;&gt; &quot;x&quot;');
  assert.match(xml, new RegExp(`device whose public key is ${'cd'.repeat(32)}`));
  // In the order NCMEC's schema has them.
  const order = ['incidentSummary', 'internetDetails', 'reporter', 'personOrUserReported'].map((e) => xml.indexOf(`<${e}>`));
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.ok(order.every((i) => i > 0));

  const bare = reportXml({ at, reporter, account: null, done: 'The picture was withheld.' });
  assert.equal(elementOf(bare, 'espIdentifier'), null, 'no account, no identifier');
  assert.equal(elementOf(bare, 'screenName'), null);
});

test("the picture's details: nobody here looked at it, and whether players were shown it", () => {
  const unseen = fileDetailsXml({ reportId: '42', fileId: 'f1', fileName: `${digest}.jpg`, at, digest, shown: false });
  assert.equal(elementOf(unseen, 'reportId'), '42');
  assert.equal(elementOf(unseen, 'fileId'), 'f1');
  assert.equal(elementOf(unseen, 'fileViewedByEsp'), 'false');
  assert.equal(elementOf(unseen, 'publiclyAvailable'), 'false');
  assert.match(unseen, new RegExp(`<nameValuePair type="HASH"><name>SHA-256</name><value>${digest}</value></nameValuePair>`));
  const shown = fileDetailsXml({ reportId: '42', fileId: 'f1', fileName: `${digest}.jpg`, at, digest, shown: true });
  assert.equal(elementOf(shown, 'publiclyAvailable'), 'true');
});

/// NCMEC's API, faked: each path answers as [answers] says (a status
/// and a body, or a function of the call), and every call is kept.
function ncmec(answers = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const path = new URL(url).pathname.replace('/ispws', '');
    calls.push({ path, init });
    const a = answers[path] ?? { 200: `<reportResponse><responseCode>0</responseCode>${path === '/submit' ? '<reportId>4564654</reportId>' : ''}${path === '/upload' ? '<fileId>b0754af766b426f2928a02c651ed4b99</fileId><hash>x</hash>' : ''}</reportResponse>` };
    const [status, body] = Object.entries(a)[0];
    return new Response(body, { status: Number(status) });
  };
  return { calls, fetchImpl };
}

const filing = (fetchImpl) =>
  fileReport({
    endpoint: 'https://exttest.cybertip.org/ispws',
    username: 'user',
    password: 'pass',
    report: '<report/>',
    jpeg: Uint8Array.from([0xff, 0xd8]),
    fileName: `${digest}.jpg`,
    details: (reportId, fileId) => `<fileDetails><reportId>${reportId}</reportId><fileId>${fileId}</fileId></fileDetails>`,
    fetchImpl,
  });

test('filed: opened, the picture uploaded and described, and finished, with the credentials on every call', async () => {
  const api = ncmec();
  assert.equal(await filing(api.fetchImpl), '4564654');
  assert.deepEqual(api.calls.map((c) => c.path), ['/submit', '/upload', '/fileinfo', '/finish']);
  for (const c of api.calls) assert.equal(c.init.headers.authorization, `Basic ${btoa('user:pass')}`);
  assert.equal(api.calls[0].init.headers['content-type'], 'text/xml; charset=utf-8');
  assert.equal(api.calls[0].init.body, '<report/>');
  const upload = api.calls[1].init.body;
  assert.equal(upload.get('id'), '4564654');
  assert.equal(upload.get('file').name, `${digest}.jpg`);
  assert.deepEqual(new Uint8Array(await upload.get('file').arrayBuffer()), Uint8Array.from([0xff, 0xd8]));
  assert.equal(api.calls[2].init.body, '<fileDetails><reportId>4564654</reportId><fileId>b0754af766b426f2928a02c651ed4b99</fileId></fileDetails>');
  assert.equal(api.calls[3].init.body.get('id'), '4564654');
});

test('a report that fails part way is taken back; one never opened has nothing to take back', async () => {
  const upload = ncmec({ '/upload': { 200: '<reportResponse><responseCode>1110</responseCode><responseDescription>Upload failed</responseDescription></reportResponse>' } });
  await assert.rejects(filing(upload.fetchImpl), (e) => e instanceof NcmecRefused && e.code === '1110' && /\/upload: 200, response code 1110: Upload failed/.test(e.message));
  assert.deepEqual(upload.calls.map((c) => c.path), ['/submit', '/upload', '/retract']);
  assert.equal(upload.calls[2].init.body.get('id'), '4564654');

  const finish = ncmec({ '/finish': { 500: 'down' } });
  await assert.rejects(filing(finish.fetchImpl), NcmecRefused);
  assert.deepEqual(finish.calls.map((c) => c.path), ['/submit', '/upload', '/fileinfo', '/finish', '/retract']);

  const submit = ncmec({ '/submit': { 401: '<reportResponse><responseCode>2000</responseCode></reportResponse>' } });
  await assert.rejects(filing(submit.fetchImpl), (e) => e.code === '2000');
  assert.deepEqual(submit.calls.map((c) => c.path), ['/submit']);

  const noId = ncmec({ '/submit': { 200: '<reportResponse><responseCode>0</responseCode></reportResponse>' } });
  await assert.rejects(filing(noId.fetchImpl), /no report id/);
});
