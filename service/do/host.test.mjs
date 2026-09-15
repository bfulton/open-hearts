// The relay over real sockets, driven by node's own WebSocket client —
// a different implementation from the one that wrote the server, which
// is the point: a handshake and a frame either follow RFC 6455 or they
// only agree with themselves.
//
//   node --test service/do/host.test.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { connect } from 'node:net';
import { after, test } from 'node:test';

import { serve, wasmPath } from './host.mjs';
import { keys, signing } from './sign.mjs';

const sign = await signing(readFileSync(wasmPath));
const relay = await serve({ port: 0 });
after(() => relay.close());

/// A client that keeps what it was told and can wait for a particular
/// message, whether it has already arrived or is still to come.
async function client(path = '') {
  const socket = new WebSocket(`${relay.url}/${path}`);
  const said = [];
  const waiting = [];
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    said.push(message);
    for (const w of [...waiting]) {
      if (w.where(message)) {
        waiting.splice(waiting.indexOf(w), 1);
        clearTimeout(w.timer);
        w.resolve(message);
      }
    }
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve);
    socket.addEventListener('error', reject);
  });
  return {
    said,
    send: (message) => socket.send(JSON.stringify(message)),
    close: () => socket.close(),
    next(where) {
      const found = said.find(where);
      if (found) return Promise.resolve(found);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('nothing like that arrived')), 5000);
        waiting.push({ where, resolve, timer });
      });
    },
  };
}

test('two clients on one tag: a beat from one reaches the other', async () => {
  const a = await client('online');
  const b = await client('online');
  const filter = { kinds: [24246], '#t': ['online'] };
  a.send(['REQ', 'online', filter]);
  b.send(['REQ', 'online', filter]);
  await Promise.all([a.next((m) => m[0] === 'EOSE'), b.next((m) => m[0] === 'EOSE')]);

  const event = await sign.event(keys[0], { kind: 24246, content: '{"kind":"here"}', tags: [['t', 'online']] });
  a.send(['EVENT', event]);
  assert.equal((await a.next((m) => m[0] === 'OK'))[2], true);
  assert.deepEqual((await b.next((m) => m[0] === 'EVENT'))[2], event);
  a.close();
  b.close();
});

test('another tag is another object: it hears nothing of the first', async () => {
  const here = await client('online');
  const elsewhere = await client('some-table');
  here.send(['REQ', 'online', { kinds: [24246] }]);
  elsewhere.send(['REQ', 'online', { kinds: [24246] }]);
  await Promise.all([here.next((m) => m[0] === 'EOSE'), elsewhere.next((m) => m[0] === 'EOSE')]);
  const event = await sign.event(keys[1], { kind: 24246, content: '{"kind":"here"}', tags: [['t', 'online']], created_at: 1001 });
  here.send(['EVENT', event]);
  await here.next((m) => m[0] === 'EVENT');
  await new Promise((r) => setTimeout(r, 100));
  assert.deepEqual(elsewhere.said.filter((m) => m[0] === 'EVENT'), []);
  here.close();
  elsewhere.close();
});

test('an event too big for one frame arrives whole', async () => {
  const a = await client('big');
  a.send(['REQ', 'all', { kinds: [1] }]);
  await a.next((m) => m[0] === 'EOSE');
  // Past 64 KiB a length no longer fits in two bytes, and a client is
  // free to send the payload in pieces; a sealed table's deal is the
  // traffic that gets here.
  const content = 'x'.repeat(200000);
  const event = await sign.event(keys[2], { kind: 1, content, created_at: 1002 });
  a.send(['EVENT', event]);
  assert.equal((await a.next((m) => m[0] === 'OK'))[2], true);
  const back = await a.next((m) => m[0] === 'EVENT');
  assert.equal(back[2].content.length, content.length);
  assert.equal(back[2].id, event.id);
  a.close();
});

test('a client that goes is forgotten, and the ones left carry on', async () => {
  const a = await client('leaving');
  const b = await client('leaving');
  b.send(['REQ', 'all', { kinds: [24246] }]);
  await b.next((m) => m[0] === 'EOSE');
  assert.equal(relay.relayFor('/leaving').connections, 2);
  a.close();
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(relay.relayFor('/leaving').connections, 1);
  const event = await sign.event(keys[3], { kind: 24246, content: '{"kind":"here"}', tags: [['t', 'online']], created_at: 1003 });
  b.send(['EVENT', event]);
  assert.deepEqual((await b.next((m) => m[0] === 'EVENT'))[2], event);
  b.close();
});

/// One frame, masked the way a client must mask: the payload here is
/// always short enough for the one-byte length.
function frame(opcode, fin, text) {
  const mask = Buffer.from([1, 2, 3, 4]);
  const payload = Buffer.from(text, 'utf8');
  for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
  return Buffer.concat([Buffer.from([(fin ? 0x80 : 0) | opcode, 0x80 | payload.length]), mask, payload]);
}

test('a message sent in pieces is read as one, and a ping is answered', async () => {
  // Node's own client sends a message as a single frame however big it
  // is, so the pieces have to be written by hand. A browser is free to
  // send them, and a server that only understands whole messages loses
  // the socket the first time one does.
  const socket = connect(relay.port, '127.0.0.1');
  await new Promise((resolve) => socket.once('connect', resolve));
  socket.write(
    'GET /pieces HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n',
  );
  const frames = [];
  let rest = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    rest = Buffer.concat([rest, chunk]);
    const head = rest.indexOf('\r\n\r\n');
    if (head >= 0) {
      // RFC 6455's own example key and the accept it must produce.
      assert.match(rest.subarray(0, head).toString(), /s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=/);
      rest = rest.subarray(head + 4);
    }
    while (rest.length >= 2 && rest.length >= 2 + (rest[1] & 0x7f)) {
      const length = rest[1] & 0x7f;
      frames.push({ opcode: rest[0] & 0x0f, text: rest.subarray(2, 2 + length).toString() });
      rest = rest.subarray(2 + length);
    }
  });

  const request = JSON.stringify(['REQ', 'half', { kinds: [1] }]);
  socket.write(frame(0x1, false, request.slice(0, 10)));
  socket.write(frame(0x0, true, request.slice(10)));
  socket.write(frame(0x9, true, 'still there?'));
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.deepEqual(JSON.parse(frames.find((f) => f.opcode === 0x1).text), ['EOSE', 'half']);
  assert.equal(frames.find((f) => f.opcode === 0xa)?.text, 'still there?');
  socket.destroy();
});
