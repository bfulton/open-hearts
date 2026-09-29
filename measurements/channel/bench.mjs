// What a WebRTC data channel carries between two browsers, and what a
// bulk transfer on it does to a small message beside it.
//
//     node measurements/channel/bench.mjs
//
// Two pages of one headless Chromium, a data channel between them,
// signalled by this script rather than a relay: the channel is what is
// being measured, not the app around it. On one machine that is the
// loopback, so the throughput is a software ceiling and not a link —
// what it answers is whether the channel itself could carry the
// volumes doc 04's computation would need, or falls over long before.
//
// The latency figures are the useful half, and they are not about the
// link either. A table's own events would share the connection with
// anything the computation sent, and what a small message waits behind
// is the sender's own queue: [HIGH_WATER] bytes of it, whatever the
// link does with them afterwards.

// A measurement's entire output is its printing.
/* eslint-disable no-console */
import { chromium } from '../../e2e/browser.mjs';

const SECONDS = Number(process.env.OH_BENCH_SECONDS ?? 6);
/// How much the sender lets pile up before it waits. A message sent
/// after it waits for all of it.
const HIGH_WATER = 8 << 20;
const SIZES = [16, 64, 256].map((k) => k * 1024);
const PINGS = 200;

const log = (s) => console.log(s);
const ms = (n) => `${n.toFixed(1)} ms`;

function quantile(xs, q) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))];
}

/// Opens a data channel between two pages and returns them. Offer and
/// answer go through here; ICE is gathered whole rather than trickled,
/// which on one machine costs nothing and keeps this script short.
async function connect(a, b) {
  const setup = async (page, role) => {
    await page.evaluate((r) => {
      window.oh = { role: r, rtt: new Map(), got: 0, pongs: [] };
      const pc = new RTCPeerConnection();
      window.oh.pc = pc;
      const wire = (dc) => {
        dc.binaryType = 'arraybuffer';
        dc.onmessage = (e) => {
          const v = new DataView(e.data);
          const kind = v.getUint8(0);
          if (kind === 0) {
            window.oh.got += e.data.byteLength;
          } else if (kind === 1) {
            const out = new Uint8Array(e.data.slice(0));
            new DataView(out.buffer).setUint8(0, 2);
            dc.send(out);
          } else {
            const id = v.getFloat64(1);
            const at = window.oh.rtt.get(id);
            if (at !== undefined) {
              window.oh.pongs.push(performance.now() - at);
              window.oh.rtt.delete(id);
            }
          }
        };
      };
      window.oh.wire = wire;
      if (r === 'a') {
        const bulk = pc.createDataChannel('bulk', { ordered: true });
        const chat = pc.createDataChannel('chat', { ordered: true });
        window.oh.bulk = bulk;
        window.oh.chat = chat;
        wire(bulk);
        wire(chat);
      } else {
        pc.ondatachannel = (e) => {
          window.oh[e.channel.label] = e.channel;
          wire(e.channel);
        };
      }
    }, role);
  };
  await setup(a, 'a');
  await setup(b, 'b');

  // Whatever has gathered after a moment, rather than the end of
  // gathering: with no STUN server to answer, this Chromium sits in
  // `gathering` for ever, and the host candidate is there at once.
  const gather = (page) =>
    page.evaluate(async () => {
      const pc = window.oh.pc;
      const until = performance.now() + 1500;
      while (pc.iceGatheringState !== 'complete' && performance.now() < until) {
        await new Promise((r) => setTimeout(r, 50));
      }
      return pc.localDescription.sdp;
    });

  await a.evaluate(async () => {
    const pc = window.oh.pc;
    await pc.setLocalDescription(await pc.createOffer());
  });
  const offer = await gather(a);
  await b.evaluate(async (sdp) => {
    const pc = window.oh.pc;
    await pc.setRemoteDescription({ type: 'offer', sdp });
    await pc.setLocalDescription(await pc.createAnswer());
  }, offer);
  const answer = await gather(b);
  await a.evaluate(async (sdp) => {
    await window.oh.pc.setRemoteDescription({ type: 'answer', sdp });
  }, answer);

  for (const page of [a, b]) {
    await page.waitForFunction(() => window.oh.bulk?.readyState === 'open' && window.oh.chat?.readyState === 'open', null, {
      timeout: 20000,
    });
  }
}

/// Sends as fast as the channel takes it for [seconds], and returns
/// what arrived at the other end.
async function throughput(a, b, chunk, seconds) {
  await b.evaluate(() => {
    window.oh.got = 0;
  });
  const sent = await a.evaluate(
    async ([chunk, seconds, high]) => {
      const dc = window.oh.bulk;
      const buf = new Uint8Array(chunk);
      dc.bufferedAmountLowThreshold = 1 << 20;
      const room = () =>
        dc.bufferedAmount <= dc.bufferedAmountLowThreshold
          ? Promise.resolve()
          : new Promise((done) => dc.addEventListener('bufferedamountlow', done, { once: true }));
      const until = performance.now() + seconds * 1000;
      let n = 0;
      while (performance.now() < until) {
        await room();
        for (let i = 0; i < 64 && dc.bufferedAmount < high; i++) {
          dc.send(buf);
          n += chunk;
        }
      }
      while (dc.bufferedAmount > 0) await new Promise((r) => setTimeout(r, 20));
      return n;
    },
    [chunk, seconds, HIGH_WATER],
  );
  // The last of it is still in flight when the sender stops.
  await b.waitForFunction((want) => window.oh.got >= want, sent, { timeout: 30000 }).catch(() => {});
  const got = await b.evaluate(() => window.oh.got);
  return { sent, got };
}

/// Round trips of a small message: on its own, and while the bulk
/// channel is being filled.
async function pings(a, n, { on = 'chat' } = {}) {
  return a.evaluate(
    async ([n, on]) => {
      const dc = window.oh[on];
      window.oh.pongs = [];
      for (let i = 0; i < n; i++) {
        const buf = new Uint8Array(64);
        const v = new DataView(buf.buffer);
        v.setUint8(0, 1);
        v.setFloat64(1, i);
        window.oh.rtt.set(i, performance.now());
        dc.send(buf);
        await new Promise((r) => setTimeout(r, 5));
      }
      const until = performance.now() + 5000;
      while (window.oh.pongs.length < n && performance.now() < until) {
        await new Promise((r) => setTimeout(r, 20));
      }
      return window.oh.pongs;
    },
    [n, on],
  );
}

const browsers = [];
try {
  // One browser, two pages. Chromium hides a machine's addresses
  // behind mDNS names that only its own profile resolves, so two
  // instances cannot reach each other here; the flag turns that off
  // and the two pages are still two peers over a real socket.
  const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-features=WebRtcHideLocalIpsWithMdns'] });
  browsers.push(browser);
  const pages = [await browser.newPage(), await browser.newPage()];
  const [a, b] = pages;
  for (const page of pages) await page.goto('about:blank');
  await connect(a, b);
  log('a data channel between two pages of one headless Chromium, over the loopback\n');

  log('sustained, one ordered channel:');
  const rates = [];
  for (const chunk of SIZES) {
    const { sent, got } = await throughput(a, b, chunk, SECONDS);
    const rate = got / SECONDS / (1 << 20);
    rates.push({ chunk, rate });
    log(`  ${String(chunk / 1024).padStart(4)} KB a message: ${rate.toFixed(1)} MB/s` + (got < sent ? `  (${sent - got} bytes never arrived)` : ''));
  }
  const best = rates.reduce((x, y) => (y.rate > x.rate ? y : x));

  log('\nround trip of a 64-byte message:');
  const idle = await pings(a, PINGS);
  log(`  idle:                       median ${ms(quantile(idle, 0.5))}, p95 ${ms(quantile(idle, 0.95))}`);

  // The same ping while the bulk channel is saturated: first beside it
  // on a channel of its own, then behind it on the same one.
  const load = throughput(a, b, best.chunk, SECONDS);
  const beside = await pings(a, PINGS);
  await load;
  log(`  beside a bulk transfer:     median ${ms(quantile(beside, 0.5))}, p95 ${ms(quantile(beside, 0.95))}`);

  const load2 = throughput(a, b, best.chunk, SECONDS);
  const behind = await pings(a, PINGS, { on: 'bulk' });
  await load2;
  log(`  behind one, same channel:   median ${ms(quantile(behind, 0.5))}, p95 ${ms(quantile(behind, 0.95))}`);

  // What the sender's own queue comes to at this rate: what a message
  // behind it waits for, and what the same queue would be worth on a
  // link people actually have.
  log(`\n${(HIGH_WATER / (1 << 20)).toFixed(0)} MB of queue, drained at:`);
  for (const [name, mbit] of [['this loopback', best.rate * 8], ['25 Mbit/s', 25], ['5 Mbit/s', 5], ['1 Mbit/s', 1]]) {
    log(`  ${name.padStart(13)}: ${((HIGH_WATER * 8) / (mbit * 1e6)).toFixed(2)} s`);
  }

  // The budget, per AND gate of the circuit a bot-held seat costs for
  // one hand (packages/engine/tool/circuit_count.dart), on links rather
  // than on this one: the channel is not what decides this.
  const GATES = 53726;
  log(`\nwhat a hand affords for a seat's ${GATES} AND gates, by link:`);
  for (const mbit of [1, 5, 25]) {
    const row = [60, 120].map((hand) => `${Math.round((mbit * 1e6 * hand) / 8 / GATES).toLocaleString()}`);
    log(`  ${String(mbit).padStart(2)} Mbit/s: ${row[0].padStart(6)} bytes a gate over a minute, ${row[1].padStart(6)} over two`);
  }
} finally {
  for (const browser of browsers) await browser.close().catch(() => {});
}
