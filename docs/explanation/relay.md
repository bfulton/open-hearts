# The relay

Live play meets on one relay, Open Hearts' own, at
`relay.openhearts.game`: one Cloudflare Durable Object per tag
(`service/do/`). This page explains why it is built that way and what
it keeps. Its tags, event kinds, limits and retention are in the
[relay reference](../reference/relay.md).

## One relay, ours

Deployed builds and the backup jurors talk to no other relay. The list
is a constant of the build (`app/lib/net/relays.dart`), and the remote
config may move tables only to another host under `openhearts.game`
([remote config](service.md#remote-config)). The wire format is
NIP-01-style signed events, our own and free to change.

## One object per tag

The tag in the path names the object, so everyone on a tag reaches the
same object wherever they are, and nothing has to be passed between
machines. Every event's id and BIP-340 signature are checked before
anything else sees it. Sockets hibernate, carrying their subscriptions
through eviction, so an idle connection costs nothing.

Each socket is held to limits on message size, request size and
publishing rate. A table's limits are looser than presence's: a deal
sends its steps in bursts of tens of kilobytes, while presence is a
small message every few seconds from every device online.

## What is kept, and why

Most of what the relay carries is forwarded and forgotten: a table's
events, signalling, pools, presence and the players' reactions. The
table protocol repeats what is unsettled, so a dropped message is
recovered without the relay keeping it.

One kind is stored, the lobby: a room announced, a pool's seating, a
table started, a player's picture, a game's result. A tag's object
stores a lobby event only when the event is tagged with that object's
own tag, so nobody can write into one tag's store through another.
Stored events live in the object's own storage, so they survive
eviction, and a new subscriber is sent them. That is how a device
arriving at a room code finds the room that was announced before it got
there.

Rooms, seatings, starts and pictures are kept only as long as a room
can be in use (`KEPT_MS` in `service/do/tag_store.mjs`). Results are
kept for good, under the tag every result carries (`GameResult.tag` in
`packages/table/lib/src/results.dart`), because every rating is folded
from all of them ([ratings](live-play.md#ratings)). They stay when an
account's data is deleted on request
([what stays](../how-to/delete-an-accounts-data.md#what-stays)).

### Withheld pictures

A picture the operator takes off an account
([suspending an account](service.md#suspending-an-account)) could
otherwise stay a day in every pool and room it was put out in, from any
of the account's devices, and the relay has no record of which those
were. So the picture is named instead: the account's turn adds the
SHA-256 of its JPEG to one list in the store (`config|pictures`,
`service/functions/pictures.mjs`), for 30 days or until it is put back.
Every tag's object that keeps a lobby reads the list when a picture
comes its way, at most once a minute (`service/do/withheld.mjs`), so
within a couple of minutes of the order every object has it:

- **Put out**, a listed picture is taken and kept: the `OK` is `true`,
  with the reason `withheld:`, and the event is neither stored nor
  passed on. Refusing it would count against the device
  (`refusalMs` in `packages/table/lib/src/relays.dart`) and hold up the
  rest of its live play for a minute, while its owner may not even know
  the picture was taken down: the device in use takes the change at
  its next renewal.
- **Already held**, it is let go of, from memory and from the object's
  storage, before a subscription is served anything.

Pictures are matched by their bytes, so the same picture put out by
anyone is withheld. Copies that devices already received stay on those
devices.

The automatic check ([pictures to look at](#pictures-to-look-at)) hides
a picture by adding it to the same list. A picture the operator puts
back after the check hid it (`./oh picture allow`) is listed apart, as
allowed, so that the check does not hide it again; the operator taking
it down later overrides that.

### Refused names

A name others would see goes through one filter in three places: the
app before it keeps or sends one, the service before it keeps one with
an account or a kept game, and the relay before it carries one
([names](service.md#names-the-others-see)). At the relay, the lobby,
waiting in a pool or a room, and a watched table are read for the names
they carry (`namesIn` in `service/do/relay.mjs`), and an event with a
refused name in it is refused: the `OK` is `false`, with the reason
`blocked: a name that is not allowed`, and the event is neither stored
nor passed on. Unlike a withheld picture, this counts against the
device, since the app never sends such a name: only a device made to
send one meets it.

### Pictures to look at

The operator looks at every new picture after it is shown, rather than holding pictures until someone has looked. When a tag's object first carries a picture, it copies it to an R2 bucket (`OH_PICTURES`, `service/do/review.mjs`), named by its SHA-256; and when it first carries a picture from an account, it notes that the account put it out. Only a subscriber's device is carried, so only subscribers' pictures are copied. A picture the operator took down is withheld before it is copied.

A picture travels only as an event of its own (`{"kind":"picture"}`), where the take-downs and the copies see it. The app never puts one inside an avatar, and the relay refuses an event that does, its own avatar or a seat's (`pictureInAvatar`), with the reason `blocked: a picture travels as its own event`; the app ignores one there too.

As a picture is first copied, a model looks at it: Cloudflare's `@cf/cloudflare/clef-flash`, through Workers AI (the `AI` binding, `checkPicture`). It is told what the picture is, a small profile picture in a card game, and asked three questions, each answered as how likely a yes is, from 0 to 1: does it show nudity or sexual content; graphic violence, injury or gore; a hate symbol. A picture with any answer of 0.5 or more is hidden: withheld as one the operator took down ([withheld pictures](#withheld-pictures)), from then on, for 30 days. The copy keeps the answers, and unless the operator allowed the picture, it is hidden again whenever it is put out while it is not withheld, so a picture whose 30 days have run out is hidden again. A check that fails leaves the picture shown, and the email says so.

The line of 0.5 comes from trying the check on pictures the size the app sends, 64 pixels square. Everyday pictures (faces, people in swimwear, a cat, an emoji, text) answered under 0.06 to every question; a swastika flag answered 0.94 to the hate symbol, and Botticelli's *Birth of Venus*, a nude painting, 0.52 to nudity. The check does not ask whether a child is shown: at that size it couldn't tell a child from an adult (a child in a costume 0.48, an adult swimmer 0.46). Instead, every picture hidden as nudity or sexual content puts its account first in the email, marked urgent, for the operator to look at that day.

Once a day the relay worker's schedule emails the operator every picture each account put out since the last email, account by account, in the order it put them out. A picture an account has since replaced is in it too, so putting a picture out and changing back before the email hides nothing. Each account's pictures come with what the check made of each and the commands that take them down or put back one hidden by mistake, and an email holds whole accounts, up to 100 pictures ([Look at the day's new pictures](../how-to/look-at-new-pictures.md)). The same run deletes the copies and notes nobody has put out for 30 days: what is still put out is written again every week or so, keeping what it first said, so it stays. It hides any picture in the email the check found should be hidden, in case hiding it as it was copied did not take, and keeps what the operator allowed allowed for as long as its copy is kept.

The copies are served at `pictures.openhearts.game`, through Cloudflare's cache, so the email can show them, and so that Cloudflare's CSAM Scanning Tool checks each against the lists of known child sexual abuse images when it first enters the cache. The tool blocks a match at that address and emails the operator. The copy at the relay is a different thing: it stops when the operator takes the picture down ([Handle a report of child sexual abuse material](../how-to/handle-abuse-material.md)).

## Reactions

A [reaction](live-play.md#reactions) is a code and the moment it was
said at, never words, and the relay holds it to that. It rides only a
table's own tag, and an object refuses one anywhere else or in any other
shape. The codes themselves are not listed in the relay, since a screen
shows only the codes it knows, so a new reaction needs no new relay.

## Watching a table

A watcher's ask and a seated player's answer ride the table's own tag.
The relay forwards both and stores neither, like the rest of a table's
traffic ([watching a live game](live-play.md#watching-a-live-game)).
