// A WebSocket server in the twenty or so rules of RFC 6455 that a
// relay needs, because node has a WebSocket client and no server and
// this repo has no dependency to add one. It is here so the JS relay
// core (relay.mjs) can be driven by the suites that have always driven
// the Dart relay: the same sockets, the same clients, a different
// relay underneath.
//
// What it does: the upgrade handshake, masked frames from the client,
// unmasked frames back, fragmentation, ping and close. What it does
// not: compression (the extension is simply not agreed to, so no
// client uses it), and subprotocols, which nothing here asks for.

import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

/// RFC 6455's constant, concatenated with the client's key and hashed
/// to prove the server understood the handshake rather than echoing it.
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// The largest message accepted, whole or in fragments. A relay's
/// events are kilobytes; a sealed table's deal is the big one and is
/// still far under this. Past it the connection goes, because the
/// alternative is holding whatever a stranger sends.
const maxMessageBytes = 16 * 1024 * 1024;

class Connection {
  constructor(socket, path) {
    this.socket = socket;
    this.path = path;
    this.onMessage = null;
    this.onClose = null;
    this._buffer = Buffer.alloc(0);
    this._fragments = [];
    this._fragmentBytes = 0;
    this._closed = false;
    this._told = false;
  }

  send(text) {
    if (this._closed) return;
    const payload = Buffer.from(text, 'utf8');
    let header;
    if (payload.length < 126) {
      header = Buffer.from([0x81, payload.length]);
    } else if (payload.length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 126;
      header.writeUInt16BE(payload.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    this.socket.write(Buffer.concat([header, payload]));
  }

  close(code = 1000) {
    if (this._closed) return;
    this._closed = true;
    const payload = Buffer.alloc(2);
    payload.writeUInt16BE(code);
    this.socket.write(Buffer.concat([Buffer.from([0x88, 2]), payload]));
    this.socket.end();
  }

  /// The connection is over, however it ended — a close frame, a reset,
  /// a process that went away. Said once: every ending arrives twice,
  /// since node reports the socket closing after we have closed it.
  _gone() {
    if (this._told) return;
    this._told = true;
    this._closed = true;
    this.onClose?.();
  }

  feed(chunk) {
    this._buffer = this._buffer.length ? Buffer.concat([this._buffer, chunk]) : chunk;
    while (this._take());
  }

  /// One frame if a whole one has arrived; false when more bytes are
  /// needed, which is the ordinary case for anything large.
  _take() {
    const b = this._buffer;
    if (b.length < 2) return false;
    const fin = (b[0] & 0x80) !== 0;
    const opcode = b[0] & 0x0f;
    const masked = (b[1] & 0x80) !== 0;
    let length = b[1] & 0x7f;
    let at = 2;
    if (length === 126) {
      if (b.length < 4) return false;
      length = b.readUInt16BE(2);
      at = 4;
    } else if (length === 127) {
      if (b.length < 10) return false;
      const big = b.readBigUInt64BE(2);
      if (big > BigInt(maxMessageBytes)) return this._tooBig();
      length = Number(big);
      at = 10;
    }
    const data = at + (masked ? 4 : 0);
    if (b.length < data + length) return false;
    const payload = Buffer.from(b.subarray(data, data + length));
    if (masked) {
      const mask = b.subarray(at, at + 4);
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    }
    this._buffer = b.subarray(data + length);
    this._frame(fin, opcode, payload);
    return !this._closed && this._buffer.length > 0;
  }

  _tooBig() {
    this.close(1009);
    return false;
  }

  _frame(fin, opcode, payload) {
    switch (opcode) {
      case 0x8: // close: say it back and go
        this.close(1000);
        this._gone();
        return;
      case 0x9: // ping: the same bytes back as a pong
        this.socket.write(Buffer.concat([Buffer.from([0x8a, payload.length]), payload]));
        return;
      case 0xa: // pong: nothing asked for one
        return;
      case 0x0: // a continuation of the message being assembled
      case 0x1: // text
      case 0x2: // binary, which the relay will not understand but is
        break; //   still assembled, so the stream stays in step
      default:
        this.close(1002);
        this._gone();
        return;
    }
    this._fragmentBytes += payload.length;
    if (this._fragmentBytes > maxMessageBytes) {
      this._tooBig();
      return this._gone();
    }
    this._fragments.push(payload);
    if (!fin) return;
    const message = this._fragments.length === 1 ? this._fragments[0] : Buffer.concat(this._fragments);
    this._fragments = [];
    this._fragmentBytes = 0;
    this.onMessage?.(message.toString('utf8'));
  }
}

/// Listens, and hands every accepted connection to [onConnection].
/// Port 0 takes any free one, which is what a test wants; the port
/// actually taken comes back.
export async function listen({ port = 0, host = '127.0.0.1', onConnection }) {
  const server = createServer((request, response) => {
    // Anything that is not an upgrade: say what this is, briefly.
    response.writeHead(426, { 'content-type': 'text/plain', upgrade: 'websocket' });
    response.end('this is a relay: open a websocket\n');
  });
  server.on('upgrade', (request, socket) => {
    const key = request.headers['sec-websocket-key'];
    if ((request.headers.upgrade ?? '').toLowerCase() !== 'websocket' || !key) {
      socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
      return;
    }
    const accept = createHash('sha1').update(key + GUID).digest('base64');
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    socket.setNoDelay(true);
    const connection = new Connection(socket, new URL(request.url, 'http://host').pathname);
    socket.on('data', (chunk) => connection.feed(chunk));
    socket.on('error', () => connection._gone());
    socket.on('close', () => connection._gone());
    onConnection(connection);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  return {
    port: server.address().port,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
