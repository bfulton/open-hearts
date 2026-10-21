# Look at the day's new pictures

Use this guide when the daily email of new pictures arrives, and once before the first one, to set it up.

Every picture a subscriber sets is shown at live tables once it is checked as it is set. An automatic check looks at each new one, and hides one it takes for nudity or sexual content, violence or gore, or a hate symbol. Once a day, at 13:00 UTC, the relay worker emails you every picture each account set since the last email, account by account, including any an account has since replaced, and what the check made of each ([how it works](../explanation/relay.md#pictures-to-look-at)). You look at them, take down any that break the terms' rules for a picture, and put back any the check hid by mistake. A picture that matches a known image of child sexual abuse is never in it: it is never the account's, and is handled without you ([Handle a report of child sexual abuse material](handle-abuse-material.md)).

## Before you begin

Do this once:

1. Check that `alerts.pictures` is `true` and `alerts.to` is your alerts address in `config/openhearts.json` ([Configuration](../reference/configuration.md#configopenheartsjson)).
1. Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes, for the commands the email gives.

## Look at the email

If the subject begins with **Urgent**, the check hid a picture as nudity or sexual content. Look at it that day: the accounts with such a picture come first.

Each account in the email has every picture it set since the last email, in order, each marked as its profile picture now or no longer its profile picture. A picture the check hid says what for, and how sure the check was, from 0 to 1. A picture whose check failed says so: look at it yourself, as with any other. A picture hidden because it couldn't be decoded, so PhotoDNA couldn't be asked about it, says so too; the app never makes one. Then come the commands for the account:

- `./oh account remove <account> picture --apply` takes its profile picture now off its profile and withholds it at the relay ([Take a name or picture off](suspend-an-account.md#take-a-name-or-picture-off)). It is there only when one of the pictures is its profile picture now.
- `./oh account suspend <account> --apply` cuts the account off at the relay ([Suspend an account](suspend-an-account.md)). Use it for a picture the account no longer uses: one it set and then replaced. The relay already carries only an account's picture now.
- `./oh picture allow <sha256> --apply` puts back a picture the check hid, one line for each. Run it only for a picture that breaks no rule ([Put back a picture hidden by mistake](#put-back-a-picture-hidden-by-mistake)).

A picture the check hid stays hidden while it is an account's picture, without a command. Take its account's picture off, or suspend the account, when the account should not go on using it.

If a picture may show the sexual abuse or exploitation of a child, don't run the command under it. Follow [Handle a report of child sexual abuse material](handle-abuse-material.md) instead, the same day: it takes the picture down, keeps what the law has you keep, and reports it.

Pictures that break no rule, and that the check didn't hide, need nothing: there is nothing to approve.

## Put back a picture hidden by mistake

Run the command the email gives under the picture, with the picture's SHA-256:

```sh
./oh picture allow <sha256>
```

It prints whether the picture is withheld and what it would do, and changes nothing. Run it again with `--apply`. The relay shows the picture again within a couple of minutes, and the check doesn't hide it again while it is kept. If you take it down later, with `./oh account remove` or because of a report, that overrides putting it back.

## If no email comes

No email means no account set a new picture. To check that the run happened, open the `open-hearts-relay` worker's logs in the dashboard around 13:00 UTC: each run logs how many pictures it deleted, how many it asked PhotoDNA about again, how many it emailed, and how many it left for the next email. A run that fails emails you.

## Learn more

- [Relay: pictures to look at](../explanation/relay.md#pictures-to-look-at)
- [Suspend an account, or take its name or picture off](suspend-an-account.md)
