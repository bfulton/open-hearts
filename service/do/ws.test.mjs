// The local WebSocket server, spoken to byte by byte: the frames a real
// client sends, and the ones a stranger might.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect } from 'node:net';
import { randomBytes } from 'node:crypto';
import { listen } from './ws.mjs';

/// A raw socket past the handshake, collecting every byte it is sent.
async function open() {
  const got = [];
  let closed;
  const done = new Promise((r) => (closed = r));
  const server = await listen({ onConnection: (c) => { c.onMessage = (m) => got.push(m); } });
  const socket = connect(server.port, '127.0.0.1');
  const bytes = [];
  await new Promise((r) => socket.once('connect', r));
  socket.write('GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
  await new Promise((r) => socket.once('data', r));
  socket.on('data', (d) => bytes.push(d));
  socket.on('close', () => closed());
  return { socket, got, closed: done, bytes: () => Buffer.concat(bytes), stop: () => { socket.destroy(); return server.close(); } };
}

function frame(opcode, payload, { fin = true, masked = true } = {}) {
  const n = payload.length;
  const head = n < 126 ? Buffer.from([0, n]) : Buffer.from([0, 126, n >> 8, n & 0xff]);
  head[0] = (fin ? 0x80 : 0) | opcode;
  if (!masked) return Buffer.concat([head, payload]);
  head[1] |= 0x80;
  const mask = randomBytes(4);
  const body = Buffer.from(payload);
  for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
  return Buffer.concat([head, mask, body]);
}

const settle = () => new Promise((r) => setTimeout(r, 50));

/// The connection's end, or a failure if it has not come: a server that
/// never closes should fail the test, not hang the suite.
const ended = (c) => Promise.race([c.closed, new Promise((_, no) => setTimeout(() => no(new Error('still open')), 2000).unref())]);

test('a ping is answered with its own bytes, and a message still arrives', async (t) => {
  const c = await open();
  t.after(c.stop);
  c.socket.write(frame(0x9, Buffer.from('are you there')));
  c.socket.write(frame(0x1, Buffer.from('hello')));
  await settle();
  assert.deepEqual(c.bytes(), Buffer.concat([Buffer.from([0x8a, 13]), Buffer.from('are you there')]));
  assert.deepEqual(c.got, ['hello']);
});

test('a ping too long to be one closes the connection rather than answering with a broken frame', async (t) => {
  const c = await open();
  t.after(c.stop);
  c.socket.write(frame(0x9, Buffer.alloc(200, 1)));
  await ended(c);
  assert.deepEqual(c.bytes(), Buffer.from([0x88, 2, 0x03, 0xea]), 'a protocol error, 1002, and nothing else');
});

test('a fragmented control frame, and an unmasked one, are not a client speaking the protocol', async (t) => {
  for (const bad of [frame(0x9, Buffer.from('x'), { fin: false }), frame(0x1, Buffer.from('hi'), { masked: false })]) {
    const c = await open();
    t.after(c.stop);
    c.socket.write(bad);
    await ended(c);
    assert.deepEqual(c.bytes(), Buffer.from([0x88, 2, 0x03, 0xea]));
    assert.deepEqual(c.got, []);
  }
});
