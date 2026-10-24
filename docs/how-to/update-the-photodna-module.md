# Update the PhotoDNA module

Use this guide to give the relay the PhotoDNA module for the first time, a new version of it from Microsoft, or a change to the relay's code that calls it.

PhotoDNA stands in for Arachnid Shield when you switch to it ([Switch the checker of known images](handle-abuse-material.md#switch-the-checker-of-known-images)). The relay is deployed with the module whichever is in use, so that switching needs no deploy.

The relay never sends PhotoDNA a picture. It decodes the picture and makes its PhotoDNA Edge Hashes itself, with a module that Microsoft licenses to Open Hearts as confidential, and sends only those ([how it works](../explanation/relay.md#known-images-of-child-sexual-abuse)). The module is Microsoft's WebAssembly and the relay's own code that calls it, and neither is in this repository. They're kept in the private R2 bucket `open-hearts-private`, each file named by its SHA-256, and `config/openhearts.json` pins the files the relay is deployed with (`photodna.module`). `./oh deploy relay --apply` fetches exactly those files, checks each against its pin, builds the relay with them in place of the stand-in `service/do/photodna_off.mjs`, and deletes them from your computer again.

A relay deployed without the module can't use PhotoDNA. While PhotoDNA is the checker in use, it checks no picture, and emails you that it was deployed without the module.

## Before you begin

- Export `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. The token needs Workers R2 Storage: Edit.
- Make sure the private bucket exists. `./oh infra --only cloudflare --apply` makes it ([Make Cloudflare, Stripe and New Relic match their definitions](apply-infrastructure.md)).
- Keep the module's folder on your own computer, outside this repository, and give it to nobody who isn't working on Open Hearts. `check.sh` fails on any committed file that is part of the module, or that says it's private.

## What the module is

A folder of files, among them `edge.mjs`. `edge.mjs` exports `edgeHashes(rgb, width, height)`, which takes a picture's pixels, three bytes each, row by row, and returns its Edge Hashes as base64 strings, at most five of them. It returns none for a picture of one colour, and throws an error whose `unhashable` is `true` for a picture too small to hash. It can import the other files in the folder, such as the WebAssembly, as a Cloudflare Worker imports them.

## Change the module

1. Get the module the relay is deployed with:

   ```bash
   ./oh photodna get ~/photodna-module
   ```

   It fetches each file `config/openhearts.json` pins and checks it against its pin. For the first module, start from the files you have instead.

1. Change the files in that folder: put in Microsoft's new WebAssembly, or change the relay's code.

1. Keep them, and pin them:

   ```bash
   ./oh photodna put ~/photodna-module
   ```

   It lists each file with its SHA-256, and changes nothing. Run it again with `--apply`. It keeps each file in the private bucket that isn't there already and writes their pins in `config/openhearts.json`.

1. Commit `config/openhearts.json`, and merge it as any other change.

1. Deploy the relay from `main`:

   ```bash
   ./oh deploy relay --apply
   ```

   It says it is deploying with the module the config pins, and how many files it has.

## Check that it works

1. Switch to PhotoDNA ([Switch the checker of known images](handle-abuse-material.md#switch-the-checker-of-known-images)).
1. In the app, set one of the sample pictures Microsoft gives with the key as your account's picture, and then set your own picture back.
1. Open the `open-hearts-relay` worker's logs in the Cloudflare dashboard. A log line says that the picture matched only Microsoft's test pictures, and that nobody is acted on for it.
1. Switch back to Shield, unless you mean to keep PhotoDNA in use.

If no such line appears, and no email says that PhotoDNA failed, the relay didn't ask PhotoDNA: check that the row names it, and the deploy's output for the module.

## Learn more

- [Handle a report of child sexual abuse material](handle-abuse-material.md)
- [The oh command](../reference/oh.md#oh-photodna-put)
- [Configuration](../reference/configuration.md#configopenheartsjson)
