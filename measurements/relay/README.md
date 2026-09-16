# What the relay path carries, and the one party that has only it

A table has two paths. Every human at it gets a WebRTC data channel,
measured in [`channel/`](../channel/README.md); the relay runs beside
them, carrying the same messages once more so that a peer whose
channel is down is still reached (`app/lib/net/mesh_transport.dart`).

A juror has only the second. It is not a peer: it is summoned, it
follows the table on its own relay list
(`packages/table/lib/src/juror_duty.dart`), and the transport the app
builds offers channels to the human seats and to nobody else
(`app/lib/home_page.dart`, `peers`). That is fine for what a juror does
today — appeals, verdicts and a share of the escrow, all of them small
— and it is the thing to know before [doc 04](../../docs/04-live-play.md)'s
computation, which at one human makes the **foreman a computing
party**. Whatever the foreman computes, it computes over a relay.

```bash
node measurements/relay/bench.mjs      # the envelope, the per-event work, the wire

cd measurements/relay && dart pub get
dart run seal.dart                     # sealing in the VM: phones
dart compile js -O2 -o seal.js seal.dart && node seal.mjs   # and on the web
```

`bench.mjs` runs the relay the object runs (`service/do/relay.mjs`) on
the node host (`service/do/host.mjs`) over a loopback socket, with real
BIP-340 signatures through the app's own wasm. Like the channel bench
it is a ceiling and not a link: a public relay is somebody else's
machine with its own limits, and our own object is a hop across the
world. What loopback measures honestly is the envelope, the work each
end must do per event, and what a small message waits behind.

## The envelope

| payload | content | wire | |
|---|---|---|---|
| 32 B | 52 | 422 | 13.2x |
| 1 KB | 1,376 | 1,746 | 1.71x |
| 16 KB | 21,856 | 22,226 | 1.36x |
| 64 KB | 87,392 | 87,762 | 1.34x |
| 256 KB | 349,536 | 349,906 | 1.33x |

An event is JSON: a 32-byte id, a 32-byte key and a 64-byte signature,
all in hex, plus the tag and the keys around them — **366 bytes** for
a content with nothing in it to escape, which is anything base64. The
1.33x is base64 itself: this wire is text, so bytes that are not text
pay a third more to cross it.

## The work per event

| payload | sign | check | sign/s | check/s |
|---|---|---|---|---|
| 32 B | 0.85–0.91 ms | 0.42–0.43 ms | 1,100–1,170 | 2,280–2,370 |
| 1 KB | 0.85–0.86 ms | 0.43–0.44 ms | 1,160–1,180 | 2,280–2,350 |
| 16 KB | 1.02 ms | 0.58–0.62 ms | 976 | 1,610–1,730 |
| 64 KB | 1.45–1.48 ms | 1.03–1.11 ms | 674–688 | 899–969 |

A signature to send one; a rehash and a signature to accept one, paid
by the relay **and again by every receiver**, since a relay is not a
friend and the app checks what it is handed. **On small events that is
most of what the path costs**: one publisher and one subscriber moved
1,640–1,680 events a second of 1 KB, which is 600 µs an event, and the
relay's own check is 435 µs of it. The socket is not the constraint;
the checking nearly is.

## What the wire does

| payload | events | payload MB/s | wire MB/s | events/s |
|---|---|---|---|---|
| 1 KB | 2,000 | 1.6 | 2.7–2.8 | 1,640–1,680 |
| 16 KB | 800 | 14.5 | 19.6–19.7 | 925–927 |
| 64 KB | 300 | 22.9–25.0 | 30.7–33.4 | 367–399 |
| 256 KB | 120 | 24.4–26.1 | 32.5–34.9 | 98–104 |

| a 64-byte message, publish to receipt | median | p95 |
|---|---|---|
| idle | 0.5–0.6 ms | 0.6–0.9 ms |
| beside a bulk stream, on another socket | 4.8–5.2 ms | 6.7–6.8 ms |
| behind 7.7 MB of one, on the same socket | 180–192 ms | 182–214 ms |

**A second socket separates about as well as a second channel does.**
On the channel a table message beside a bulk transfer cost 15 ms
against 0.8 idle; here it costs 4.8–5.2 ms against 0.5. An order of
magnitude either way, and a few milliseconds either way. What is
shared differs: there a congestion window, here the relay itself, one
queue checking a signature and rehashing every event that passes
through it. On an object that queue is per tag and so belongs to this
table alone; on a public relay it is everybody's, and this loopback
had nothing else to do.

**And the sender's own queue is the same story as the channel's.** 7.7
MB handed over at once drains in 180 ms on loopback and holds up
everything behind it for that long. On 5 Mbit/s it is 12.6 seconds —
twice the six-second grace a play gets and a quarter of the seat's
whole time bank (`packages/table/lib/src/time_bank.dart`), spent
waiting behind the sender's own upload.

## Sealing, which the relay path needs and the channel does not

A channel is between two peers. A relay is a stranger's machine that
carries the event, which is why signalling is already sealed to its
recipient with NIP-44 v2 (`packages/table/lib/src/nip44.dart`), and
why anything else addressed to one party would be. NIP-44 is Dart, not
wasm, so the web app pays dart2js for it:

| plaintext | encrypt | decrypt | encrypt MB/s | decrypt MB/s |
|---|---|---|---|---|
| 256 B | 0.24 ms | 0.12 ms | 1.0 | 2.0 |
| 1 KB | 0.27 ms | 0.16 ms | 3.6 | 6.0 |
| 16 KB | 2.17 ms | 1.41 ms | 7.2 | 11.1 |
| 64 KB | 8.96 ms | 5.86 ms | 7.0 | 10.7 |

The Dart VM does 8.4 and 11.5 MB/s at the same size, so dart2js costs
about a fifth here — where the same comparison for BIP-340 was tenfold
([`sign/`](../sign/README.md), 104 ms against 11). ChaCha20 is
`Uint32List` arithmetic, which dart2js compiles well; BIP-340 was
bignum arithmetic, which it does not.

**One sealed event carries 49,143 bytes of payload.** NIP-44 caps a
plaintext at 65,535, and the cap lands on the *message* — the payload
is already base64 inside it. So the payload is expanded twice, once
into the message and once when the sealed message is base64 again:
49,143 bytes of payload, 65,532 of message, 87,472 sealed, 87,838 on
the wire. **1.79x**, against 1.33x unsealed and 1.0 on a channel.

## What that gives doc 04

The triple is measured now too ([`ot/`](../ot/README.md)): one
authenticated AND triple a gate, 53,726 gates, **772 bytes a triple**
at the bucket a hand's batch needs and 579 at the smaller bucket a
game's batch allows. Over the relay path, for the foreman:

| | a hand's batch | a game's |
|---|---|---|
| bucket | 4 | 3 |
| payload | 39.6 MB | 29.7 MB |
| sealed events | 844 | 633 |
| on the wire | 70.7 MB | 53.0 MB |
| to seal, on the web | 7.6 s | 5.7 s |
| to open | 5.0 s | 3.7 s |
| to sign, and to check at each end | 1.2 s, 0.9 s | 0.9 s, 0.7 s |
| **on a 5 Mbit/s uplink** | **119 s** | **89 s** |

A hand is p50 a minute and p90 two. So **a foreman on the relay works
only at the pace of a slow hand**, and only with the preprocessing a
hop ahead — which the design already has it doing. At the batch size a
whole game allows there is a little room; at a hand's, none.

**The budget, in the channel bench's units.** 5 Mbit/s for a minute is
37.5 MB of wire; at 1.79x that is 21 MB of payload, which is **390
bytes a gate — against the channel's 700.** Sealing and the envelope
leave the foreman a little over half of what a seated player has to
spend, and the triple costs 772.

**Which is the finding.** The relay carries a foreman, but with nothing
to spare: the same preprocessing that takes 66 seconds of a seated
player's uplink takes 119 of a juror's, because it crosses two links
with a third more on it for base64 and a third again for the seal. If
that is too tight — and at a p50 hand it is — the answer is not a
bigger relay: it is to give a juror a data channel, which is a change
to `MeshTransport` (a juror is announced on presence, signalled like a
peer and offered a channel like one) rather than to the protocol.
