# Handle a report of child sexual abuse material

Use this guide when the relay emails you about a known image it blocked, or when a report, or anything else, makes you aware that a picture or name published through Open Hearts may show the sexual abuse or exploitation of a child.

A picture that matches a known image of child sexual abuse is handled without you: the Canadian Centre for Child Protection's Arachnid Shield, or Microsoft's PhotoDNA in its place, checks each new picture as an account sets it, before anyone is shown it, and the relay withholds a match, holds and terminates the accounts that set it, reports it to NCMEC and emails you what it did ([how it works](../explanation/relay.md#known-images-of-child-sexual-abuse)). For a picture you find yourself, one command has the relay do the same ([Report a picture you found](#report-a-picture-you-found)). The rest of this guide is for a name, for finishing anything the relay emails you it couldn't do, and for when it can't act at all.

US federal law requires a provider that gets actual knowledge of apparent child sexual abuse material to report it to the CyberTipline of the National Center for Missing & Exploited Children (NCMEC) as soon as reasonably possible, and to keep the report's contents for one year after it is made ([18 U.S.C. §2258A](https://www.law.cornell.edu/uscode/text/18/2258A); the year comes from the [REPORT Act of 2024](https://www.govinfo.gov/content/pkg/PLAW-118publ59/html/PLAW-118publ59.htm)). Act on the same day.

## Before you begin

Do this once, before any report arrives:

- Register Open Hearts with NCMEC as an electronic service provider, by email to [espteam@ncmec.org](mailto:espteam@ncmec.org) ([NCMEC](https://www.missingkids.org/csam)). The law requires a provider's registration to be kept current. Keep its details in your own records, not in this repository.
- Until the registration is in place, report through the public CyberTipline at [report.cybertip.org](https://report.cybertip.org/) or on 1-800-843-5678.
- Request an Arachnid Shield account at [projectarachnid.com](https://projectarachnid.com/) (Shield, then **Request an account**), for Bright Fulton LLC. It's free. Shield checks that its crawler is let in on Open Hearts' hosts: `site/public/robots.txt` and `app/web/robots.txt` name it, with the token Arachnid gave. Once the account is approved, set its username and password, which are kept only as the relay worker's secrets:

  ```bash
  ./oh secret set OH_ARACHNID_USERNAME --apply
  ./oh secret set OH_ARACHNID_PASSWORD --apply
  ```

  Shield is the checker in use unless you switch.
- So that PhotoDNA can stand in for Shield, set the key Microsoft gives with access to its PhotoDNA Cloud Service on the relay worker, and give the relay the PhotoDNA module ([Update the PhotoDNA module](update-the-photodna-module.md)):

  ```bash
  ./oh secret set OH_PHOTODNA_KEY --apply
  ```

  Nothing is sent to PhotoDNA until you switch to it.
- Ask NCMEC, once Open Hearts is registered, for credentials for its CyberTipline reporting API, and set them:

  ```bash
  ./oh secret set OH_NCMEC_USERNAME --apply
  ./oh secret set OH_NCMEC_PASSWORD --apply
  ```

  The config sends reports to NCMEC's test service (`ncmec.endpoint`) until one has gone through there; then change it to `https://report.cybertip.org/ispws` and deploy the relay. Until both are done, the relay emails you to report each match by hand.
- Export `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` and `STRIPE_API_KEY`, as [Suspend an account](suspend-an-account.md#before-you-begin) describes. The token needs Workers R2 Storage: Edit, to find an account by its picture and to hold it.

## When the relay emails you about a known image

The email says which account put the picture out, what was done, and what wasn't, with the command for each step left. It never holds the picture.

- **Nothing needs you:** the email says so. Keep it.
- **An automatic step failed:** the relay tries it again by itself, and emails you again when what is done changes. If one stays undone, run the command the email gives for it.
- **Report it yourself:** the email says so while NCMEC's credentials aren't set, or while reports go to its test service. [Report it](#report-it) as below, with the copy the hold kept.

Every other failure of the automatic handling, such as the checker not answering, also emails you, at most once in six hours for each kind. A picture the checker couldn't check is shown, and checked again until it can be. If the checker keeps failing, [switch to the other](#switch-the-checker-of-known-images).

## Switch the checker of known images

Arachnid Shield checks each new picture unless you put PhotoDNA in its place, for example while Shield doesn't answer, or while its account is suspended. Switching takes one command and no deploy, and it's undone the same way.

1. Check that PhotoDNA is ready: its key is set on the relay worker, and the relay was deployed with the module. `./oh deploy relay` says which module it deploys with ([Update the PhotoDNA module](update-the-photodna-module.md)).
1. Write the row to a file, `known.json`:

   ```json
   { "checker": "photodna" }
   ```

1. See what it would replace, then write it:

   ```bash
   ./oh config set known known.json
   ./oh config set known known.json --apply
   ```

   The relay reads it as it asks about the next picture, within a minute or so. If the checker you switch to lacks what it needs, the relay checks nothing and emails you what's missing.

1. To go back to Shield, delete the row:

   ```bash
   ./oh config clear known --apply
   ```

What either checker said of a picture stands after a switch: a picture one cleared isn't asked about again, and one either matched stays a match. Each picture's copy keeps which checker said what of it, and when, and the daily email says so for each picture ([Look at the day's new pictures](look-at-new-pictures.md)).

## When the relay emails you about a harmful picture

Arachnid Shield also knows images that are harmful or abusive to a child without being child sexual abuse material. The relay refuses such a picture, withholds it wherever it turns up, deletes the account's copy of it and emails you, but doesn't hold, terminate or report the account: that's yours to decide. No copy of the picture is kept, so there's nothing to look at. If the account shouldn't go on, suspend it with the command the email gives ([Suspend an account](suspend-an-account.md)). If you have reason to think it's child sexual abuse material after all, follow the rest of this guide.

## What not to do

- Don't download, screenshot, copy, forward or show the material to anyone, except to make the report. Look at it no more than you need to decide.
- Don't tell the account's owner about the report.
- Don't delete anything of the account's, except its copy of the picture, which this guide says to delete once the hold has kept it: the law has it kept. `./oh account hold` makes sure nothing else does.

## Find the account

- **From a report:** find the account by the name it plays under, or the report's account number, and set it in your shell, as [Suspend an account](suspend-an-account.md#find-the-account) shows.
- **From a picture:** find the accounts that set it, by its SHA-256 or the address of an account's copy of it:

  ```bash
  ./oh account find <sha256>
  ```

  It prints each account that set it in the last year, and whether it is the account's profile picture now. Set each in your shell in turn, and follow the rest of this guide for each one.

## Report a picture you found

For a picture that may show the sexual abuse or exploitation of a child, from a player's report, the daily email of new pictures or anywhere else, once you have looked at it:

```bash
./oh picture report <sha256> --how 'a player reported it' --apply
```

The relay then does what it does for a match with a known image: it withholds the picture wherever it was put out, holds and terminates each account that set it in the last year, their web subscriptions ended with nothing refunded, reports it to NCMEC saying you looked at it and `--how` you came to, and emails you what it did. Whoever sets the picture after that is acted on too. Run it without `--apply` first to see which accounts set it.

It needs a copy of the picture: an account's own copy, kept for a year after it stops being the account's ([how it works](../explanation/relay.md#an-accounts-pictures)), or one kept from an account. For a picture already taken off an account's profile, or kept by its hold, name the account with `--account <account>`. When there is no copy, which is a picture no account has had for a year, the command says so: follow the steps below by hand.

## Take it down and hold the account by hand

For a name, or a picture the relay can't act on:

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

   It also keeps a copy of each picture the account set in the last year, at `held/<account>/<sha256>.jpg` in the bucket of kept games, `open-hearts-records`, which has no address of its own, and prints each one it keeps. The account's own copy of each picture is deleted a year after it stops being the account's, which the hold may outlast, so these are the copies the law has you keep.

1. End the account, as a serious breach, with no refund:

   ```bash
   ./oh account terminate "$account" --serious --apply
   ```

1. Delete the account's copy at `pictures.openhearts.game`, now that the hold has kept one:

   ```bash
   ops/wrangler/wrangler r2 object delete "open-hearts-pictures/account/$account/<sha256>.jpg" --remote
   ```

## Report it

1. Make the report to the CyberTipline, unless the relay's email gives a report number already. Give what you know: the picture or name, when you learned of it and how, the account's number, its devices' keys (`./oh account show` lists how many; the report can ask for them), and, for a web subscription, the email address in Stripe. The picture is the copy the hold kept, or, for a profile picture taken off, the base64 JPEG under `picture` in the account's `HELD` row. Download it only to attach it to the report, and delete the download as soon as it is attached:

   ```bash
   ops/wrangler/wrangler r2 object get "open-hearts-records/held/$account/<sha256>.jpg" --remote --file picture.jpg
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
