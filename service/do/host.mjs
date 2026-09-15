// The JS relay core on a plain node socket: the same relay the
// Cloudflare object runs (worker.mjs), hosted where the repo's tests
// can reach it.
//
//   node service/do/host.mjs                 # relay on 7448
//   node service/do/host.mjs --port 0        # any free port, said on stdout
//
// One relay per path, as on Cloudflare: `ws://host/online` is the
// object for the tag `online` and nothing it carries is visible at
// another path. The root is a tag like any other here — the object
// host insists on one, because it has to name an object before it can
// route to it, while a lone process has nothing to look up.
//
// Two things a test needs and a deployment never does, both off unless
// asked for: `--stats <path>` keeps a small JSON file of what the Dart
// tests read as `relay.stored` and `relay.connections`, written before
// the reply that would let a test look; and `--control` puts a policy
// on stdin, so a Dart test that has installed a `refuse` policy is
// asked about each event and its answer is what this relay does. The
// asking is real: a test that counts how often its policy was
// consulted counts what the relay actually consulted.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

import { createRelay, memoryStore, schnorrVerifier, tagOf } from './relay.mjs';
import { listen } from './ws.mjs';

/// The signature wasm the app carries, checked by the same code in the
/// browser (app/lib/crypto/schnorr_web.dart) and here.
export const wasmPath = new URL('../../app/web/schnorr.wasm', import.meta.url);

/// The local relay takes the simulator's signatures as well as real
/// ones, told apart by their length, which is what the Dart relay does
/// and for the same reason: a simulated table and a real one then share
/// every line of protocol code, half the repo's suites seat their
/// players with a `FakeSigner`, and neither has to pay for a signature
/// it is not testing (packages/table, signing.dart). A fake one is a
/// hash anybody could compute, so it belongs to a machine running its
/// own tests and nowhere else — the object on Cloudflare (worker.mjs)
/// knows BIP-340 and refuses everything else.
export function alsoFakeSignatures(verify) {
  const fake = (key, digest) => createHash('sha256').update(`${key}|${digest}`).digest('hex').slice(0, 32);
  return (key, digest, signature) => (signature.length === 32 ? fake(key, digest) === signature : verify(key, digest, signature));
}

/// A relay per tag on one port. [refuse] and [log] are handed to every
/// relay; [onChange] is called whenever the counts a test watches move,
/// before anything is written back to the socket that moved them.
export async function serve({ port = 0, host = '127.0.0.1', keep = 10000, log = null, refuse = null, onChange = null } = {}) {
  const verify = alsoFakeSignatures(await schnorrVerifier(readFileSync(wasmPath)));
  const relays = new Map();
  const relayFor = (path) => {
    const tag = tagOf(path);
    if (tag === null) return null;
    let relay = relays.get(tag);
    if (!relay) {
      relay = createRelay({ verify, store: memoryStore(keep), refuse, log: log && ((line) => log(tag ? `${tag}: ${line}` : line)) });
      relays.set(tag, relay);
    }
    return relay;
  };
  const counts = () => {
    let stored = 0;
    let connections = 0;
    for (const relay of relays.values()) {
      stored += relay.stored;
      connections += relay.connections;
    }
    return { stored, connections };
  };
  const changed = () => onChange?.(counts());

  const server = await listen({
    port,
    host,
    onConnection: (connection) => {
      const relay = relayFor(connection.path);
      // A path that names no object: nothing here answers to it.
      if (!relay) return connection.close(1008);
      // The relay says everything through this: the counts it has just
      // moved are written down before the client can be told anything
      // that would make it look at them.
      const socket = {
        send: (text) => {
          changed();
          connection.send(text);
        },
      };
      relay.open(socket);
      changed();
      connection.onMessage = (text) => relay.message(socket, text);
      connection.onClose = () => {
        relay.close(socket);
        changed();
      };
    },
  });
  return {
    port: server.port,
    url: `ws://${host}:${server.port}`,
    counts,
    relayFor,
    close: () => server.close(),
  };
}

/// The relay as a process: the arguments, the line a harness reads, and
/// the two test hooks.
async function main(argv) {
  let port = 7448;
  let keep = 10000;
  let quiet = false;
  let stats = null;
  let control = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') port = Number(argv[++i]);
    if (argv[i] === '--keep') keep = Number(argv[++i]);
    if (argv[i] === '--quiet') quiet = true;
    if (argv[i] === '--stats') stats = argv[++i];
    if (argv[i] === '--control') control = true;
  }

  // A policy on the other end of stdin: ask, and wait for the answer.
  // Nothing is asked while the other end says it has no policy, so an
  // ordinary run never pays for this.
  const asked = new Map();
  let asking = 0;
  let policy = false;
  const refuse = control
    ? (event) => {
        if (!policy) return null;
        const id = ++asking;
        process.stdout.write(`${JSON.stringify({ ask: id, event })}\n`);
        return new Promise((resolve) => {
          const timer = setTimeout(() => {
            asked.delete(id);
            resolve(null);
          }, 5000);
          asked.set(id, (reason) => {
            clearTimeout(timer);
            resolve(reason);
          });
        });
      }
    : null;
  if (control) {
    createInterface({ input: process.stdin }).on('line', (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      if (typeof message.refuse === 'boolean') policy = message.refuse;
      if (typeof message.answer === 'number') asked.get(message.answer)?.(message.reason ?? null);
      if (message.answer !== undefined) asked.delete(message.answer);
    });
  }

  let last = '';
  const onChange = stats
    ? (counts) => {
        const line = JSON.stringify(counts);
        if (line === last) return;
        last = line;
        writeFileSync(stats, line);
      }
    : null;

  const relay = await serve({ port, keep, log: quiet ? null : (line) => process.stdout.write(`${line}\n`), refuse, onChange });
  onChange?.(relay.counts());
  // Always say where, even when quiet: a harness reads this line.
  process.stdout.write(`relay ${relay.url}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}
