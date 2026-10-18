# Look at the day's new pictures

Use this guide when the daily email of new pictures arrives, and once before the first one, to set it up.

Every picture a subscriber puts out at a live table is shown at once. Once a day, at 13:00 UTC, the relay worker emails you the pictures put out for the first time since the last email, at most 100 at a time ([how it works](../explanation/relay.md#pictures-to-look-at)). You look at them, and take down any that break the terms' rules for a picture.

## Before you begin

Do this once:

1. Turn on Cloudflare's CSAM Scanning Tool for the `openhearts.game` zone: in the dashboard, open the zone, then **Caching**, then **Configuration**, and turn on **CSAM Scanning Tool**. Give it the address the alerts go to. It checks each picture against the lists of known child sexual abuse images as it is first served from `pictures.openhearts.game`, blocks a match there, and emails you.
1. Check that `alerts.pictures` is `true` and `alerts.to` is your alerts address in `config/openhearts.json` ([Configuration](../reference/configuration.md#configuration-file)).
1. Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes, for the commands the email gives.

## Look at the email

Each picture in the email has the account that put it out, when it was first put out, and a command:

- **Its profile picture**: `./oh account remove <account> picture --apply` takes it off the account's profile and withholds it at the relay ([Take a name or picture off](suspend-an-account.md#take-a-name-or-picture-off)).
- **Not its profile picture now**: the account has since changed its picture, or a changed app put out one that was never its profile's. `./oh account suspend <account> --apply` cuts the account off at the relay ([Suspend an account](suspend-an-account.md)).

If a picture may show the sexual abuse or exploitation of a child, don't run the command under it. Follow [Handle a report of child sexual abuse material](handle-abuse-material.md) instead, the same day: it takes the picture down, keeps what the law has you keep, and reports it.

Pictures that break no rule need nothing: there is nothing to approve.

## If no email comes

No email means nothing new was put out. To check that the run happened, open the `open-hearts-relay` worker's logs in the dashboard around 13:00 UTC: each run logs how many pictures it emailed, how many it left for the next email, and how many copies it deleted.

## Learn more

- [Relay: pictures to look at](../explanation/relay.md#pictures-to-look-at)
- [Suspend an account, or take its name or picture off](suspend-an-account.md)
