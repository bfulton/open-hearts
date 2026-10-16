# Handle a report of child sexual abuse material

Use this guide when a report, or anything else, makes you aware that a picture or name published through Open Hearts may show the sexual abuse or exploitation of a child.

US federal law requires a provider that gets actual knowledge of apparent child sexual abuse material to report it to the CyberTipline of the National Center for Missing & Exploited Children (NCMEC) as soon as reasonably possible, and to keep the report's contents for one year after it is made ([18 U.S.C. §2258A](https://www.law.cornell.edu/uscode/text/18/2258A); the year comes from the [REPORT Act of 2024](https://www.govinfo.gov/content/pkg/PLAW-118publ59/html/PLAW-118publ59.htm)). Act on the same day.

## Before you begin

Do this once, before any report arrives:

- Register Open Hearts with NCMEC as an electronic service provider, by email to [espteam@ncmec.org](mailto:espteam@ncmec.org) ([NCMEC](https://www.missingkids.org/csam)). The law requires a provider's registration to be kept current. Keep its details in your own records, not in this repository.
- Until the registration is in place, report through the public CyberTipline at [report.cybertip.org](https://report.cybertip.org/) or on 1-800-843-5678.
- Export `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` and `STRIPE_API_KEY`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes.

## What not to do

- Don't download, screenshot, copy, forward or show the material to anyone, except to make the report. Look at it no more than you need to decide.
- Don't tell the account's owner about the report.
- Don't delete anything of the account's: the law has it kept. `./oh account hold` makes sure nothing does.

## Take it down and hold the account

1. Find the account, by the name it plays under or from the report, and set it in your shell, as [Suspend an account](suspend-an-account.md#find-the-account) shows.

1. Take the picture off, or the name:

   ```bash
   ./oh account remove "$account" picture --apply
   ```

   This takes it off the profile and keeps it beside the account, in its `HELD` row, which is the copy the law has you keep. The relay withholds the picture at once ([Suspend an account](suspend-an-account.md#take-a-name-or-picture-off)).

1. Hold the account's data:

   ```bash
   ./oh account hold "$account" --apply
   ```

   For a year from today, nothing deletes the account's data, nothing taken off it is put back, and a later removal keeps what was held first beside it. A deletion its owner asks for meanwhile is noted, and done once the hold is released.

1. End the account, as a serious breach, with no refund:

   ```bash
   ./oh account terminate "$account" --serious --apply
   ```

## Report it

1. Make the report to the CyberTipline. Give what you know: the picture or name, when you learned of it and how, the account's number, its devices' keys (`./oh account show` lists how many; the report can ask for them), and, for a web subscription, the email address in Stripe. The picture is the base64 JPEG under `picture` in the account's `HELD` row: copy it out only to attach it to the report, and delete that copy as soon as it is attached.

1. Record the report's number on the hold:

   ```bash
   ./oh account hold "$account" --ref 123456789 --apply
   ```

1. Check that it holds:

   ```bash
   ./oh account show "$account"
   ```

   It prints `under a legal hold: held since <day>, until at least <day>, for report <number>`.

Keep access to the account's data to yourself. If law enforcement asks you to keep it longer, keep the hold in place.

## Release the hold

After the year, unless you were asked to keep the data longer:

```bash
./oh account release "$account" --apply
```

It refuses before the year is out. Once released, the account's data is kept and deleted as the [privacy policy](https://openhearts.game/privacy) says. If its owner asked meanwhile for it to be deleted, the command says so: delete it then, as [Delete an account's data on request](delete-an-accounts-data.md) describes.

## Learn more

- [The oh command](../reference/oh.md)
- [Service handlers and storage](../reference/service-api.md#storage): the `HOLD` and `HELD` rows.
