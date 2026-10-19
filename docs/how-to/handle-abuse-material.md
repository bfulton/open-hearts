# Handle a report of child sexual abuse material

Use this guide when a report, an email from Cloudflare's CSAM Scanning Tool, or anything else makes you aware that a picture or name published through Open Hearts may show the sexual abuse or exploitation of a child.

US federal law requires a provider that gets actual knowledge of apparent child sexual abuse material to report it to the CyberTipline of the National Center for Missing & Exploited Children (NCMEC) as soon as reasonably possible, and to keep the report's contents for one year after it is made ([18 U.S.C. §2258A](https://www.law.cornell.edu/uscode/text/18/2258A); the year comes from the [REPORT Act of 2024](https://www.govinfo.gov/content/pkg/PLAW-118publ59/html/PLAW-118publ59.htm)). Act on the same day.

## Before you begin

Do this once, before any report arrives:

- Register Open Hearts with NCMEC as an electronic service provider, by email to [espteam@ncmec.org](mailto:espteam@ncmec.org) ([NCMEC](https://www.missingkids.org/csam)). The law requires a provider's registration to be kept current. Keep its details in your own records, not in this repository.
- Until the registration is in place, report through the public CyberTipline at [report.cybertip.org](https://report.cybertip.org/) or on 1-800-843-5678.
- Turn on Cloudflare's CSAM Scanning Tool, as [Look at the day's new pictures](look-at-new-pictures.md#before-you-begin) describes. Cloudflare's page on the tool says that the report, and keeping what it needs for a year, are likely still yours to make ([Cloudflare](https://developers.cloudflare.com/cache/reference/csam-scanning/)).
- Export `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` and `STRIPE_API_KEY`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes. The token needs Workers R2 Storage: Edit, to find an account by its picture and to hold it.

## What not to do

- Don't download, screenshot, copy, forward or show the material to anyone, except to make the report. Look at it no more than you need to decide.
- Don't tell the account's owner about the report.
- Don't delete anything of the account's, except the one copy this guide says to once the hold has kept it: the law has it kept. `./oh account hold` makes sure nothing else does.

## Find the account

- **From a report:** find the account by the name it plays under, or the report's account number, and set it in your shell, as [Suspend an account](suspend-an-account.md#find-the-account) shows.
- **From Cloudflare's CSAM Scanning Tool:** its email comes once a day and lists the path of each picture it matched at `pictures.openhearts.game`, such as `/review/<sha256>.jpg`, and whether it blocked it there. Find the accounts that put the picture out:

  ```bash
  ./oh account find /review/<sha256>.jpg
  ```

  It prints each account that put it out in the last 30 days, and whether it is the account's profile picture now. Set each in your shell in turn, as [Suspend an account](suspend-an-account.md#find-the-account) shows, and follow the rest of this guide for each one.

The tool blocks only the copy at `pictures.openhearts.game`, not the picture at the relay, which goes on showing it to players until you take it down.

## Take it down and hold the account

1. Take the picture down, or the name:

   - The account's profile picture now, or its name: take it off the profile.

     ```bash
     ./oh account remove "$account" picture --apply
     ```

     This takes it off the profile and keeps it beside the account, in its `HELD` row. The relay withholds the picture at once ([Suspend an account](suspend-an-account.md#take-a-name-or-picture-off)).

   - A picture that is no longer its profile picture, as `oh account find` says: withhold it at the relay instead, wherever it was put out.

     ```bash
     ./oh picture hide <sha256> --apply
     ```

1. Hold the account's data:

   ```bash
   ./oh account hold "$account" --apply
   ```

   For a year from today, nothing deletes the account's data, nothing taken off it is put back, and a later removal keeps what was held first beside it. A deletion its owner asks for meanwhile is noted, and done once the hold is released.

   It also keeps a copy of each picture the account put out in the last 30 days, at `held/<account>/<sha256>.jpg` in the bucket of kept games, `open-hearts-records`, which has no address of its own, and prints each one it keeps. The relay deletes its own copies 30 days after a picture was last put out, so these are the copies the law has you keep.

1. End the account, as a serious breach, with no refund:

   ```bash
   ./oh account terminate "$account" --serious --apply
   ```

1. If Cloudflare's email says it couldn't block the picture, delete the copy at `pictures.openhearts.game`, now that the hold has kept one:

   ```bash
   npx wrangler r2 object delete "open-hearts-pictures/review/<sha256>.jpg" --remote
   ```

## Report it

1. Make the report to the CyberTipline. Give what you know: the picture or name, when you learned of it and how, the account's number, its devices' keys (`./oh account show` lists how many; the report can ask for them), and, for a web subscription, the email address in Stripe. The picture is the copy the hold kept, or, for a profile picture taken off, the base64 JPEG under `picture` in the account's `HELD` row. Download it only to attach it to the report, and delete the download as soon as it is attached:

   ```bash
   npx wrangler r2 object get "open-hearts-records/held/$account/<sha256>.jpg" --remote --file picture.jpg
   ```

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

It refuses before the year is out. It deletes the pictures the hold kept. Once released, the account's data is kept and deleted as the [privacy policy](https://openhearts.game/privacy) says. If its owner asked meanwhile for it to be deleted, the command says so: delete it then, as [Delete an account's data on request](delete-an-accounts-data.md) describes.

## Learn more

- [The oh command](../reference/oh.md)
- [Service handlers and storage](../reference/service-api.md#storage): the `HOLD` and `HELD` rows.
