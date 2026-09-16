# What a data channel carries, and what it costs the table

[Doc 04](../../docs/04-live-play.md)'s computation would put a bot-held
seat's hand through a circuit of **53,726 AND gates** a hand
(`packages/engine/tool/circuit_count.dart`), and the part that decides
whether that is affordable is not the garbling but the preprocessing —
one authenticated triple a gate, sent a hop ahead, over the same WebRTC
connection the table plays on. Before any of it is built, two things
are worth knowing: whether the channel itself could carry that at all,
and what carrying it does to the table's own messages.

```bash
node measurements/channel/bench.mjs
```

Two pages of one headless Chromium, one `RTCPeerConnection` between
them, offer and answer passed by the script rather than by a relay:
what is measured is the channel, not the app around it. Chromium hides
a machine's addresses behind mDNS names only its own profile resolves,
so the run turns that off (`--disable-features=WebRtcHideLocalIpsWithMdns`)
and the two pages are still two peers over a real socket.

Headless Chromium 141 on the dev box, three runs:

| | |
|---|---|
| sustained, 16 KB a message | 23–30 MB/s |
| sustained, 64 KB a message | 47–49 MB/s |
| sustained, 256 KB a message | 31–52 MB/s |
| round trip of 64 bytes, idle | 0.8 ms median, 1.1 ms p95 |
| the same, **beside** a bulk transfer on its own channel | 15 ms median, 21 ms p95 |
| the same, **behind** one on the same channel | 60–120 ms median |

**The channel is not the constraint.** Tens of megabytes a second over
the loopback is far more than any hand would ask of it, so nothing
about SCTP, the browser's implementation, or moving the buffers through
JavaScript rules the design out. This is a ceiling and not a link: what
a phone on a real connection does is the other half, and this machine
has no way to emulate one.

**What a small message waits behind is the sender's own queue.** The
bulk sender here lets 8 MB pile up before it waits, and 8 MB is the
whole of the difference between the last two rows: at 47 MB/s it drains
in 0.18 s, and the table's own message, queued behind it on the same
ordered channel, waits about that long. On a link people actually have,
the same 8 MB is:

| | |
|---|---|
| 25 Mbit/s | 2.7 s |
| 5 Mbit/s | 13.4 s |
| 1 Mbit/s | 67 s |

Which is the finding. **Preprocessing cannot share a channel with the
table**, and it cannot be handed to the stack in bulk and forgotten: a
seat that queues a hand's worth of material and then has to play a card
would sit behind its own upload for as long as the link takes to drain
it, and the table would boot it for silence. Its own channel costs 15
ms while it runs — the two still share one congestion window — and that
is affordable. The queue has to be paced as well as separated.

**And the budget, per gate.** The gate count is fixed and measured, so
what a link affords is arithmetic:

| link | a hand of a minute | of two minutes |
|---|---|---|
| 1 Mbit/s | 140 bytes a gate | 279 |
| 5 Mbit/s | 698 bytes a gate | 1,396 |
| 25 Mbit/s | 3,490 bytes a gate | 6,980 |

A hand is p50 a minute and p90 two ([doc 04](../../docs/04-live-play.md),
"Per hand, not per game"), and a seat on a phone should be assumed to
have the middle row at best. **So an authenticated triple, sent a hop
ahead, has about seven hundred bytes to fit in** — and if the
construction costs more than that, the design needs a smaller circuit,
a longer hop, or a different protocol. That is the number the next step
has to be measured against, and it did not need the protocol built to
find.
