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

### An account's pictures

A picture enters where its account sets it: the app sends it with the account's profile (`service/functions/profile.mjs`), and the account's turn, which runs in the relay worker, checks it and keeps it before any player is shown it (`accountPictures` in `service/do/profile_pictures.mjs`). It asks PhotoDNA whether the picture is a known image of child sexual abuse ([known images](#known-images-of-child-sexual-abuse)), and a model whether it should be hidden ([pictures to look at](#pictures-to-look-at)). It keeps the account's own copy of it in an R2 bucket (`OH_PICTURES`), at `account/<account>/<sha256>.jpg`, and all that is known of the picture travels with that one object, in its metadata: when the account first set it, when it last set it, what the model made of it, what PhotoDNA said, when the operator was emailed it, and, once it is no longer the account's picture, since when. Two accounts that set the same picture each have their own copy, checked, emailed and acted on for each. The account's picture now is the one it set last, unless that one says it has ended: the account took its picture off, or was deleted, and set none since. So a save is one write, of the picture set last, and the account never has two pictures now. The save then makes the picture before it say since when it is no longer the account's, which is what the copy is kept a year from; a save that stopped before it did leaves that to the next save or the daily run, which take it from when the next picture was set. A change to a copy's metadata is written only if nothing else wrote the copy since it was read (`changePicture` in `service/functions/pictures.mjs`, by its etag), so the account's turn and the daily run never undo each other's change, and a copy deleted meanwhile is never written back. Only a subscriber has an account, so only subscribers' pictures are kept.

The relay carries a picture only as its account's picture now. A tag's object lists the copies of the account of the device that put it out (`ownedScreen`), and a picture that is not the one the account set last, or that has ended, is taken and kept as a withheld one is, with the reason `withheld: not this account's picture`. So a picture nobody checked, one the account no longer has, and one a changed app puts out that was never its profile's are never carried, and neither is any picture when the copies can't be read. Being the account's picture now is not the same as being shown: a picture the check or the operator hid is withheld all the same ([pictures to look at](#pictures-to-look-at)), and the account then shows none, not the one before, which no device of its puts out. A room or a pool waits for a profile save already on its way before it opens (`settled` in `app/lib/net/account_profile.dart`), so a picture changed a moment ago is the account's before the device puts it out.

A picture travels only as an event of its own (`{"kind":"picture"}`), where the take-downs and this check see it. The app never puts one inside an avatar, and the relay refuses an event that does, its own avatar or a seat's (`pictureInAvatar`), with the reason `blocked: a picture travels as its own event`; the app ignores one there too.

Nobody is shown a picture once it is no longer its account's. Its copy is kept for a year after that (`PICTURE_KEPT_DAYS` in `service/do/review.mjs`), as long as a hold keeps one reported (`HOLD_DAYS`), whether the account replaced it, the operator took it off, or the account was deleted; then the daily run deletes the copy, each account's oldest first, and none while one before it does not yet say it has ended, which would otherwise become the account's picture now. The same run makes each copy but the one an account set last say since when it is no longer the account's, if it does not yet, and reads no profile to do it. An account deleted by `oh account delete`, outside its turn, leaves a mark in the records bucket, and the run takes the account's picture now as no longer its own from when the mark was made, so it is still kept a year from the deletion and no longer. The run never makes a picture an account's, since only the account's turn checks one.

### Pictures to look at

The operator looks at every new picture after it is shown, rather than holding pictures until someone has looked.

As an account's copy of a picture is made, a model looks at it: Cloudflare's `@cf/cloudflare/clef-flash`, through Workers AI (the `AI` binding, `checkPicture` in `service/do/review.mjs`). It is told what the picture is, a small profile picture in a card game, and asked three questions, each answered as how likely a yes is, from 0 to 1: does it show nudity or sexual content; graphic violence, injury or gore; a hate symbol. A picture with any answer of 0.5 or more is hidden: withheld as one the operator took down ([withheld pictures](#withheld-pictures)), from then on, for 30 days. The copy keeps the answers, and unless the operator allowed the picture, the daily run hides it again while it is an account's picture, so a picture whose 30 days have run out is hidden again. A check that fails leaves the picture shown, and the email says so.

The line of 0.5 comes from trying the check on pictures the size the app sends, 64 pixels square. Everyday pictures (faces, people in swimwear, a cat, an emoji, text) answered under 0.06 to every question; a swastika flag answered 0.94 to the hate symbol, and Botticelli's *Birth of Venus*, a nude painting, 0.52 to nudity. The check does not ask whether a child is shown: at that size it couldn't tell a child from an adult (a child in a costume 0.48, an adult swimmer 0.46). Instead, every picture hidden as nudity or sexual content puts its account first in the email, marked urgent, for the operator to look at that day.

Once a day the relay worker's schedule goes over every copy, and does only what the copy's own metadata says is still to do: delete it, ask PhotoDNA again, hide it again, or email it. It emails the operator every picture each account set since the last email, account by account, in the order it set them. A picture an account has since replaced is in it too, so setting a picture and changing back before the email hides nothing. Each account's pictures come with what the check made of each and the commands that take them down or put back one hidden by mistake, and an email holds whole accounts, up to 100 pictures ([Look at the day's new pictures](../how-to/look-at-new-pictures.md)). It hides any picture the check found should be hidden, in case hiding it as it was set did not take, and keeps what the operator allowed allowed for as long as a copy of it is kept. The run keeps the pictures for as long as is said above whether or not the email is turned on, and a run that fails emails the operator (`alertPicturesProblem` in `service/functions/alerts.mjs`).

The copies are served at `pictures.openhearts.game`, so the email can show them; a copy's address is its account and its picture's SHA-256, which nobody can work out without both, or the email. A picture that matches a known image of child sexual abuse is never an account's, so never copied, unless it was set while PhotoDNA could not say, and then each account's copy is deleted as the match is acted on for it ([known images](#known-images-of-child-sexual-abuse)).

### Known images of child sexual abuse

As an account sets a new picture, its turn asks Microsoft's PhotoDNA whether the picture matches a known image of child sexual abuse (`service/do/known.mjs`). It asks through one object, `KnownPictures`, made in Cloudflare's `us` jurisdiction, so every request PhotoDNA gets comes from the United States, and that object remembers what PhotoDNA said of each picture, so a picture is asked about once. A match is never kept: the profile is saved without it, the note of the picture the account had before says it no longer is, and the device is told nothing it isn't told of any save. A picture set while PhotoDNA had no key, or while the account's turn could not reach the object, is kept, its copy saying so, and the daily run asks about it again for each account that set it, whether or not the account still has it: each was shown while it did.

A picture the operator finds and looks at is handled the same way: `oh picture report` writes it in the store and names it to the relay (`POST /known`), and the object treats it as a match, from then on, with a report that says the operator looked at it and how they came to. The relay worker reads the report from the store before the object hears of it, so a request that names none, which anybody can send, never reaches the one object every new picture waits on. The object keeps what it answered for as long as the report is kept, so the tool asking again, its answer lost, is told the same and nothing is done twice.

Everything after a match is done by the `KnownPictures` object, with nobody waiting on the operator:

1. The picture is withheld wherever it turns up ([withheld pictures](#withheld-pictures)), even one the operator had put back, and each account's copy of it is deleted, as its case holds the picture until the account's hold has it.
1. Each account that set it is held for a year at the least ([Handle a report of child sexual abuse material](../how-to/handle-abuse-material.md)), with a copy of the picture and of every other picture it set in the records bucket, which no address serves.
1. Each such account is terminated, by an order the service carries out in the account's turn, which also ends its web subscriptions in Stripe with nothing refunded (`orderRoute` in `service/functions/worker.mjs`).
1. A report is filed to NCMEC's CyberTipline through its reporting API (`service/functions/ncmec.mjs`): the picture, when it was set, the account's number, the name it played under, the key of the device that set it, and that nobody at Open Hearts looked at it. The report's number is written on the hold.
1. The operator is emailed what was done, and anything not done yet.

Each step is written down as it is done, and the rest tried again by the object's alarm, a minute later and then twice as long each time, up to six hours, until all are. The operator is emailed again whenever what is done changes. If PhotoDNA does not answer, the picture is set, so the game goes on, and asked about again on the same schedule; a match found then is acted on for every account that set it, from when it was first set, and each account's copy is deleted.

Every failure emails the operator, at most once in six hours for each kind (`alertKnownProblem` in `service/functions/alerts.mjs`): PhotoDNA not answering, an account's turn unable to reach the `KnownPictures` object, a step that failed, the daily run unable to wake the object, the key set without PhotoDNA's address, and anything else that goes wrong in the object. Only a failure to send email is left to the logs.

The check is off until the relay has the secret `OH_PHOTODNA_KEY` and the config's `photodna.endpoint` is set. Reports are filed once the relay also has `OH_NCMEC_USERNAME` and `OH_NCMEC_PASSWORD`, to the service `ncmec.endpoint` names ([Configuration](../reference/configuration.md#configopenheartsjson)). Until then, and while that is NCMEC's test service, the email says to report a match by hand.

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
