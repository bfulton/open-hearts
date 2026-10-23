# List of Dirty, Naughty, Obscene, and Otherwise Bad Words

The English, Spanish, Portuguese, German and French lists from
[List of Dirty, Naughty, Obscene, and Otherwise Bad Words](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words)
by Shutterstock and its contributors, at commit
`5faf2ba42d7b1c0977169ec3611df25a3c08eb13`, unchanged: `en`, `es`, `pt`,
`de` and `fr`. They are licensed under the
[Creative Commons Attribution 4.0 International licence](https://creativecommons.org/licenses/by/4.0/),
in `LICENSE`.

Open Hearts uses them to refuse a player's name that others would see
(`service/functions/names.mjs`, `app/lib/names.dart`). `build.mjs`
makes the forms both read from these lists:
`service/functions/blocked_names.mjs` and `app/lib/blocked_names.dart`.

## What Open Hearts changes in using them

The files here are as published. What changes is how they are read:

- **Folded.** Each entry is matched as a name is: in lower case, with
  accents and other marks folded to plain letters, and the digits and
  signs often written for letters read as those letters (`0` as `o`,
  `1` as `i`, `3` as `e`, `4` as `a`, `5` as `s`, `7` as `t`, `@` as
  `a`, `$` as `s`) in any word that has a letter in it.
- **Whole words.** An entry matches a whole word of a name, or the same
  word with a plural's *s*, so *Cassandra* and *Scunthorpe* are names
  like any other. A phrase matches its words in a row, or run together
  as one word. Letters spelled out one at a time, as in `f u c k`, are
  read as a word, and so are words run together with a capital, as in
  `ShitHead`.
- **Anywhere.** Three words are refused even inside another word:
  *faggot*, *fuck* and *nigger* (`ANYWHERE` in `build.mjs`). They are
  Open Hearts' own choice, not the lists': words that no real name or
  everyday word has inside it.
- **Left out.** Entries that would refuse real names, or words people
  put in a name for no harm (`LEFT_OUT` in `build.mjs`, with the reason
  for each):
  - Names and surnames: *amador*, *aranha*, *ariano*, *butt*,
    *concha*, *dick*, *gerber*, *mong*, *mufti*, *pau*, *pinto*,
    *poon*, *quim*, *rosette*, *santorum*, *shota* and *xana*; and
    *möse* and *péter*, which fold to *Mose* and *Peter*.
  - Everyday words: *bitte* (German for *please*), *comer*, *con*,
    *inferno*, *infierno*, *mama*, *martillo*, *Trio*, *big black*,
    *girl on*, *hard core* and *hardcore*, *jelly donut*, *tainted love*
    and *tied up*.
  - Short words that are words in other languages: *cu*, *cul* and
    *Pis*.
  - `xx` and `s&m`: matched as words, they refuse a name ending in XX
    and anyone with the initials S and M.

To change the lists, replace these files with a later commit's, update
the commit above, and run `node third_party/ldnoobw/build.mjs`. The
service's tests fail while what it makes is out of date, while an entry
left out is no longer on its list, and while an entry on the lists is
not refused as a name.
