# Handle a report from a player

Use this guide when an email arrives with the subject **Open Hearts: a player's picture reported**, **Open Hearts: a player's name reported** or **Open Hearts: a player reported**.

A player sends a report from the app: they hold another player's badge at the table, choose **Report**, say what is wrong — the picture, the name or something else — and can add a note. The email comes at once, whatever the `alerts` switches in `config/openhearts.json` say. Only a subscriber can send one, at most 10 a day, and the same report once a day ([the `report` handler](../reference/service-api.md#handlers)). The player reported is not told, and the player who reported is told only that it was sent.

## Before you begin

Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes, for the commands the email gives.

## Read the report

The email says:

- Which account reported which, when, and at which table.
- What the reporter wrote, if anything.
- For a picture, a link to the copy the relay kept ([Look at the day's new pictures](look-at-new-pictures.md)), and whether it is still the account's profile picture.
- The name the reporter saw, and whether it is still the account's name.

If the picture may show the sexual abuse of a child, stop and follow [Handle a report of child sexual abuse material](handle-abuse-material.md) instead, the same day.

## Decide and act

Judge the report against the terms' rules for a live table: a name or picture that is hateful, sexual, violent, harassing or illegal, or that infringes someone's rights, and cheating or harassing. Then run the command the email gives for what you decide:

- `./oh account remove <account> picture --apply` or `./oh account remove <account> name --apply` takes the picture or the name off the account's profile ([Take a name or picture off](suspend-an-account.md#take-a-name-or-picture-off)).
- `./oh account suspend <account> --apply` cuts the account off from live play ([Suspend an account](suspend-an-account.md#suspend-the-account)).
- `./oh account show <account>` shows how the account stands first.

Each command prints what it would do and changes nothing until you add `--apply`.

A report that breaks no rule needs nothing. If one account keeps sending reports that break no rule, that is harassment too, and its own account can be suspended the same way.

## Learn more

- [Suspend an account, or take its name or picture off](suspend-an-account.md)
- [Look at the day's new pictures](look-at-new-pictures.md)
