# Launch — store listing

The App Store and Google Play listings, the screenshots, an Apple Ads
plan for the first day, and the same fields in Spanish, Brazilian
Portuguese, German and French.

Every count in this file is measured, not typed:
`node docs/launch/count-fields.mjs` rewrites them after an edit, and
`--check` fails if one is stale or a field is over its limit. Characters
are Unicode code points. App Store keywords are limited in **bytes**
(App Store Connect: "up to 100 bytes"), so an accented letter costs
two; their counts are in bytes.

## What the copy may claim

The first store build is solo only, and the copy says so by saying
nothing else. A phone build of today's code cannot reach a relay or the
service (docs/launch/privacy.md, "The answer first"), the deal's native
library is not bundled (README, roadmap 9), and there is no store
billing (roadmap 8). So the copy below claims only what that build
does:

| Claimed | Where it is |
|---|---|
| Hearts against three bots, standard rules, moon shooting | `packages/engine` |
| bots with names and temperaments, forty of them, measured | `persona.dart`, doc 04 |
| tapping an illegal card names the rule | `refusalFor`, `table_model.dart` |
| a game to 50 | `gameOverScore`. A solo player cannot choose 100: the options sheet lives in the live area |
| phone and tablet, portrait and landscape | doc 05 |
| honours reduce motion | `MediaQuery.disableAnimations`, doc 05 |
| recent games kept and counted on the device | `record_store.dart` keeps 30; `stats.dart` |
| no ads, no account, nothing to buy, works offline, nothing leaves the phone | true of a native build today |
| open source, MIT | `LICENSE` |

Not claimed, because not built on phones: live play, multiplayer or
"online", ratings, friends' tables, the verifiable deal, households,
sign-in, sync between devices, picture filtering, any purchase. The
[live play add-on](#live-play-add-on-not-for-the-first-release) is
ready for the day they are.

Three more rules the copy keeps:

- **No "free" in a name, subtitle or keyword field.** Apple's guideline
  2.3.7 rules out pricing terms in metadata, and Google's metadata policy
  rules out promotional terms in a title. The description may say solo
  play is free.
- **No other app's name in the metadata** (2.3.7 again). Competitors are
  for Apple Ads bids only, and even there with care.
- **No bot names that belong to someone else's franchise in the copy.**
  The roster includes Westley and Buttercup (*The Princess Bride*), Han
  and Leia (*Star Wars*) and Aragorn and Arwen (Tolkien). The copy names
  only Romeo, Cyrano, Casanova and Don Juan. Whether the app itself
  should carry the others is a question for the owner and a lawyer.

## Before submitting

Found while writing this; none is a copy change.

- **The live area on a phone.** A store build shows "Live play · $2.99 a
  year · Subscribe", and the subscribe page says that until the app is
  in the stores "live play is bought on the web". Outside the US
  storefront, pointing iOS users at a web purchase is steering under App
  Review guideline 3.1.1, and showing a price for something the app
  cannot sell invites a rejection on both stores. Decide whether store
  builds hide the live area until store billing exists.
- **The domain.** The privacy policy URL, the support URL and the
  marketing URL are required fields. `openhearts.game` is not attached
  yet (README). Until it is, the policy is at
  `https://open-hearts.pages.dev/privacy`.
- **The Android launcher label** reads `open_hearts`
  (`AndroidManifest.xml`).
- **iOS purpose strings** for camera and microphone may be demanded
  because `flutter_webrtc` links them (privacy.md).
- **A privacy policy link inside the app** — both stores want one; the
  About page has none.

## English

### App Store

**Name**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Classic Card Game
```
Count: 30 of 30 characters

Names are unique across the App Store. "Hearts: Classic Card Game" is the
plainer title and is likely taken; the brand in front makes this one
available and still puts "hearts" and "card game" in the most heavily
weighted field.

**Subtitle**
<!-- limit=30 unit=chars -->
```text
Offline trick-taking, no ads
```
Count: 28 of 30 characters

**Keywords** — words already in the name and subtitle are indexed from
there and are left out here, as are "free", competitors and other
games.
<!-- limit=100 unit=bytes -->
```text
spades,queen,shoot,moon,black,lady,whist,cards,bots,computer,solo,single,player,strategy,rules,learn
```
Count: 100 of 100 bytes (100 characters)

**Promotional text** — can be changed without a new build.
<!-- limit=170 unit=chars -->
```text
Hearts as you remember it: pass three, dodge the queen of spades, shoot the moon. Three named bots, no ads, nothing to buy, and it all works offline.
```
Count: 149 of 170 characters

**Description**
<!-- limit=4000 unit=chars -->
```text
Hearts, the classic card game for four, done properly: you against three bots, on your phone, with nothing in the way.

Pass three cards. Follow suit. Dodge the queen of spades and every heart you can — or take them all and shoot the moon. Lowest score wins.

NO ADS, NO SIGN-UP
There are no ads, no accounts, no daily streaks and no chips to buy. You open it, you play a hand, you close it. It works offline, and nothing about you leaves your phone.

BOTS WITH NAMES
Your opponents are famous lovers — Romeo, Cyrano, Casanova, Don Juan and dozens more — and each plays with a temperament of its own. One can't hold on to the queen; another waits for the moment; another runs at the moon with a hand nobody else would try. Underneath, they all play the same strong game, and every one of them is measured, not guessed at.

IT TELLS YOU WHY
Tap a card you can't play and it says which rule stopped you, instead of just refusing.

THE RULES
• Four players, thirteen cards each.
• Pass three cards: left, then right, then across, then no pass at all.
• The two of clubs leads. Follow suit whenever you can.
• Hearts can't be led until one has been played.
• Every heart is a point; the queen of spades is thirteen.
• Take all 26 and you shoot the moon: everyone else takes them instead.
• The game ends when someone reaches 50. Lowest score wins.

ANY SCREEN
Phone or tablet, portrait or landscape: the table is laid out for the space it has. It respects your device's reduce-motion setting.

YOUR GAMES STAY YOURS
Your recent games are kept on your phone, and your profile counts them up: games, wins, best score. Nothing is uploaded.

OPEN SOURCE
Open Hearts is MIT-licensed and built in the open. Read the rules engine, read the bots, file an issue: github.com/bfulton/open-hearts
```
Count: 1780 of 4000 characters

**Other fields**

| Field | Value |
|---|---|
| Primary category | Games — subcategories Card, Strategy |
| Age rating | answer the questionnaire for a solo build: no user-generated content, no chat, no gambling or simulated gambling. Expect the lowest rating. Live play changes the user-generated-content answers |
| Price | free; no in-app purchases in the first release |
| Support URL | <https://github.com/bfulton/open-hearts/issues> (or a contact page, once there is a contact address) |
| Marketing URL | <https://openhearts.game/> once attached |
| Privacy policy URL | <https://openhearts.game/privacy> once attached |
| Copyright | the owner's legal name — owner to decide (privacy.md) |
| App Privacy | Data Not Collected, for the solo build (privacy.md) |

### Google Play

**Title**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Classic Card Game
```
Count: 30 of 30 characters

**Short description**
<!-- limit=80 unit=chars -->
```text
Hearts against three named bots. No ads, no sign-up, and it works offline.
```
Count: 74 of 80 characters

**Full description** — the App Store description above, unchanged.
Google indexes the full description for search where Apple does not, and
it already says "Hearts", "card game", "queen of spades", "shoot the
moon" and "offline" in sentences rather than in a list, which is what
Google's policy on repetitive keywords wants. Its count is the App Store
description's.

**Other fields**: category Card; tags as Play Console offers them
(card, classic, offline, single player); target audience 13 and over
(privacy.md, children); Data safety "no data collected or shared" for
the solo build; contact email required by Play Console — owner to
decide.

### Live play add-on (not for the first release)

For the day live play works on that platform with the store's own
billing. Add the paragraph to the description, change the promotional
text, and redo the privacy answers (privacy.md, "Live play on iPhone, as
designed"). Leave the price out of the copy: each storefront shows its
own. The paragraph's limit of a thousand characters is set here, not by
a store, to keep the description well inside 4,000 with it; the
promotional text below replaces the first release's.

<!-- limit=1000 unit=chars -->
```text
LIVE PLAY
Play people, by subscription. Tap Play live and you're at a table in seconds with whoever is waiting, or send a link to three friends. Seats nobody takes are filled by bots, and a bot always says it is one. Rated games move a rating built from results everyone at the table signs. The cards are dealt between your devices with a shuffle no player controls, so no server sees a hand — ours included. At live tables your name, picture and results are public. Playing alone stays free.
```
Count: 492 of 1000 characters

<!-- limit=170 unit=chars -->
```text
Hearts against bots, free for good — or play live with people, matched in seconds, on a deal nobody can rig. No ads, no accounts.
```
Count: 129 of 170 characters

## Screenshots

### Which screens, and in what order

The first three are what most people see in search results, so they
carry the case: it is Hearts, it is clean, and it explains itself.

| # | Screen | How to get it |
|---|---|---|
| 1 | A trick in progress, portrait: the fan of cards, three bots' badges with names, a card on the table | any solo hand, after the first trick |
| 2 | The pass: three cards raised, "Pass" waiting | the first hand of a game |
| 3 | The refusal: a card tapped that cannot be played, and the rule it broke | try to lead a heart before one has been played |
| 4 | The hand's score sheet after a moon | play until somebody shoots; the bots do it about one hand in fourteen (README) |
| 5 | The bots up close: three badges with names everyone knows | a game seats three of the forty at random; retake until they are Romeo, Cyrano, Casanova, Don Juan or Cleopatra rather than the franchise characters |
| 6 | Landscape on a tablet: the wide table with the rail of played cards | an iPad, or a tablet emulator |
| 7 | The profile: games played and won, average, best | after a few solo games |

Live play, when it ships on phones: the front door with **Play live**
and the count online; a live table with a person's picture and a bot
saying it is one; the deal line ("Shuffling (2 of 4)").

### Captions

Six words or fewer, one line on a phone, in the order of the table
above.

<!-- limit=6 unit=words -->
```text
Hearts, the way you remember
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Pass three. Dodge the queen.
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Tap a card, learn the rule
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Shoot the moon
```
Count: 3 of 6 words

<!-- limit=6 unit=words -->
```text
Rivals with names and tempers
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Any screen, either way up
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
No ads. Nothing leaves your phone.
```
Count: 6 of 6 words

Live, later: "Real people, matched in seconds" and "A deal nobody can rig".

### Sizes

From Apple's screenshot specifications and Google's preview-asset
requirements as read on 1 October 2026. These change most autumns —
check both pages on the day of submission.

**App Store** — 1 to 10 screenshots per localization, JPEG or PNG, no
transparency.

| | Required? | Portrait pixels |
|---|---|---|
| iPhone 6.9" | yes, for an app that runs on iPhone | 1260 × 2736; 1290 × 2796 and 1320 × 2868 also accepted |
| iPhone 6.5" | only if no 6.9" set is given | 1284 × 2778 or 1242 × 2688 |
| iPhone 6.3" and smaller | no — scaled from the larger sets | |
| iPad 13" | yes, for an app that runs on iPad — this one does (`UISupportedInterfaceOrientations~ipad`) | 2064 × 2752 or 2048 × 2732 |
| iPad 12.9", 11" | no — scaled from 13" | |

Optional: up to three app previews (video) per size. The 6.9" size of
1260 × 2736 is new enough that older guides do not list it; it was on
Apple's page when read.

**Google Play**

| | Required? | Pixels |
|---|---|---|
| App icon | yes | 512 × 512 PNG |
| Feature graphic | yes | 1024 × 500, JPEG or PNG without alpha |
| Phone screenshots | 2 to 8 | each side 320–3840, the long side at most twice the short; 1080 × 1920 (9:16) for promotion |
| 7" and 10" tablet screenshots | optional; at least 4 each to be shown as made for tablets | each side 1080–7680, 9:16 or 16:9 |
| Games | — | at least three 1920 × 1080 landscape screenshots, and a preview video, for some of Play's game placements |

Not sure: whether Google treats the video as needed for a card game to
appear in those placements at all, or only recommends it. Its page says
a game "requires a preview video to be shown in certain parts of Google
Play".

## Apple Ads — the first day

Apple Search Ads was renamed **Apple Ads** in 2025. Use the
Advanced tier, which takes keywords; Basic does not. The app has to be
live in the store first.

### Keyword groups

Search results placement only, United States, English, iPhone and iPad.

| Campaign | Ad group | Match | Keywords | Note |
|---|---|---|---|---|
| Hearts | Core | exact | hearts · hearts card game · play hearts · hearts free | "free" is fine as a bid; it is only metadata that may not say it |
| Hearts | Category | exact | card games | broad intent, dearer, lower conversion — its own ad group so its spend can be read apart |
| Hearts | Online | exact | hearts online | **paused until live play is on phones.** Today it would buy taps from people looking for multiplayer the app does not have |
| Discovery | Broad | broad + Search Match | hearts · hearts card game | every exact keyword above added here as a negative exact, so the two never bid against each other |
| Competitor | Brands | exact | hearts plus · hearts++ | bidding on another app's name is allowed and may draw a complaint; nothing of theirs goes in our metadata. Apple may read "hearts++" as "hearts" — if it does, drop it, since Core already bids on that |
| Adjacent | Card games | exact | spades · euchre · solitaire | people who like card games, not Hearts players. Expect a low tap-through rate |

### Fifty dollars

| Campaign | Daily budget |
|---|---|
| Hearts (Core $20, Category $5 by bid) | $25 |
| Discovery | $10 |
| Adjacent | $10 |
| Competitor | $5 |
| **Total** | **$50** |

Bids: start each keyword at the middle of the range Apple suggests for
it, and at the low end for Adjacent and Competitor. Prices for card-game
keywords were not checked for this plan; whatever the dashboard
suggests is better information than a guess here.

### What to measure

- **Impressions**, per keyword: whether the term has any volume at this
  bid at all.
- **Tap-through rate** (taps ÷ impressions): whether the name, subtitle,
  icon and first screenshots — which are the ad — appeal to people who
  searched that. Compare groups with each other rather than against a
  number.
- **Average cost per tap** against the bid.
- **Conversion rate** (installs ÷ taps): whether the product page
  persuades. A high tap-through rate with low conversion means the ad
  promised something the page does not show.
- **Cost per install**, per group: the number the budget moves on.
- **The search terms report** from Discovery: terms that convert go to
  Core as exact; terms that do not go in as negatives.

$50 is a few dozen taps. The first day says which groups are served and
what people search; it does not pick winners. Read a week before moving
money, then move it toward the group with the lowest cost per install
that still has volume, and stop any keyword that has spent twice that
cost without an install.

**Do not add attribution to the app.** Apple Ads reports installs from
the store's side with nothing in the app. Calling AdServices for an
attribution token and sending it anywhere would be collecting data, and
"Data Not Collected" would go with it. What is lost is retention by
keyword, which the first week does not need.

## Translations

The app itself speaks English, Spanish, Brazilian Portuguese, German and
French, chosen from the device's language, and each description says so.
The game's established local names are used where there is one:

| Language | Name used | Why |
|---|---|---|
| Spanish | **Corazones** | the Spanish name of the game; Windows shipped it as *Corazones* |
| Brazilian Portuguese | **Copas** | the Brazilian name; Windows shipped it as *Copas* |
| German | **Hearts**, with **Schwarze Lady** in the subtitle and **Herzeln** in the keywords | German players and Windows say *Hearts*. *Schwarze Lady* is the German name of the Hearts game with the queen of spades at thirteen; *Herzeln* is the older Austrian and German name for the family |
| French | **Dame de pique** | the French name of the game; Windows shipped it as *La Dame de pique* |

Rule terms follow each language's usual card vocabulary: *picas,
tréboles* in Spanish; *espadas, paus* in Portuguese; *Pik, Kreuz* and
*Farbe bedienen* in German; *pique, trèfle, fournir* in French. Two
phrases want a native reader before they ship: "shoot the moon" (*disparar
a la luna*, *atirar na lua*, *den Mond schießen* are the common
renderings; French Hearts players more often say *faire le grand
chelem*, which is what is used here) and the reduce-motion setting,
named by its iOS label in each language.

Spanish is written to serve both es-MX and es-ES. Apple's US storefront
is widely reported to index es-MX metadata as well as English, which
would make the Spanish keyword field a second set of US keywords —
check before relying on it.

### Español

**App Store — Name**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Corazones
```
Count: 22 of 30 characters

**Subtitle**
<!-- limit=30 unit=chars -->
```text
Juego de cartas sin anuncios
```
Count: 28 of 30 characters

**Keywords**
<!-- limit=100 unit=bytes -->
```text
picas,reina,luna,naipes,baraja,bazas,clásico,estrategia,solo,offline,bots,reglas,aprender
```
Count: 90 of 100 bytes (89 characters)

**Promotional text**
<!-- limit=170 unit=chars -->
```text
Corazones como lo recuerdas: pasa tres cartas, esquiva la reina de picas, dispara a la luna. Tres bots con nombre, sin anuncios, nada que comprar y sin conexión.
```
Count: 161 of 170 characters

**Description** (App Store and Google Play)
<!-- limit=4000 unit=chars -->
```text
Corazones (Hearts), el clásico juego de cartas para cuatro, bien hecho: tú contra tres bots, en tu teléfono, sin nada en medio.

Pasa tres cartas. Sigue el palo. Esquiva la reina de picas y todos los corazones que puedas, o llévatelos todos y dispara a la luna. Gana la puntuación más baja.

SIN ANUNCIOS, SIN REGISTRO
No hay anuncios, ni cuentas, ni rachas diarias, ni fichas que comprar. La abres, juegas una mano y la cierras. Funciona sin conexión, y nada sobre ti sale de tu teléfono.

BOTS CON NOMBRE
Tus rivales son amantes célebres —Romeo, Cyrano, Casanova, Don Juan y muchos más— y cada uno juega con su propio carácter. Uno no sabe guardarse la reina; otro espera su momento; otro va a por la luna con una mano que nadie más intentaría. Por debajo, todos juegan el mismo juego sólido, y cada uno está medido, no supuesto.

TE DICE POR QUÉ
Toca una carta que no puedes jugar y te dice qué regla te lo impide, en lugar de limitarse a rechazarla.

LAS REGLAS
• Cuatro jugadores, trece cartas cada uno.
• Se pasan tres cartas: a la izquierda, a la derecha, al de enfrente y, luego, ninguna.
• Sale el dos de tréboles. Hay que seguir el palo siempre que se pueda.
• No se puede salir con corazones hasta que se haya jugado uno.
• Cada corazón vale un punto; la reina de picas, trece.
• Quien se lleva los 26 dispara a la luna: se los comen los demás.
• La partida termina cuando alguien llega a 50. Gana la puntuación más baja.

CUALQUIER PANTALLA
Teléfono o tableta, en vertical o en horizontal: la mesa se adapta al espacio que tiene. Respeta el ajuste «Reducir movimiento» de tu dispositivo.

TUS PARTIDAS SON TUYAS
Tus partidas recientes se guardan en tu teléfono y tu perfil las cuenta: partidas, victorias, mejor resultado. No se sube nada.

CÓDIGO ABIERTO
Open Hearts tiene licencia MIT y se desarrolla en abierto. Lee el motor de reglas, lee los bots, abre una incidencia: github.com/bfulton/open-hearts

La aplicación está en español, inglés, portugués, alemán y francés.
```
Count: 1985 of 4000 characters

**Google Play — Title**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Corazones
```
Count: 22 of 30 characters

**Short description**
<!-- limit=80 unit=chars -->
```text
Corazones contra tres bots con nombre. Sin anuncios, sin registro, sin conexión.
```
Count: 80 of 80 characters

**Captions**
<!-- limit=6 unit=words -->
```text
Corazones, como lo recuerdas
```
Count: 4 of 6 words

<!-- limit=6 unit=words -->
```text
Pasa tres. Esquiva la reina.
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Toca una carta, aprende la regla
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Dispara a la luna
```
Count: 4 of 6 words

<!-- limit=6 unit=words -->
```text
Rivales con nombre y carácter
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Cualquier pantalla, vertical u horizontal
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Sin anuncios. Nada sale del teléfono.
```
Count: 6 of 6 words

### Português (Brasil)

**App Store — Name**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Copas
```
Count: 18 of 30 characters

**Subtitle**
<!-- limit=30 unit=chars -->
```text
Jogo de cartas sem anúncios
```
Count: 27 of 30 characters

**Keywords**
<!-- limit=100 unit=bytes -->
```text
espadas,dama,lua,baralho,vazas,clássico,estratégia,offline,bots,regras,aprender,sozinho,whist
```
Count: 95 of 100 bytes (93 characters)

**Promotional text**
<!-- limit=170 unit=chars -->
```text
Copas do jeito que você lembra: passe três cartas, fuja da dama de espadas, atire na lua. Três bots com nome, sem anúncios, nada para comprar e funciona offline.
```
Count: 161 of 170 characters

**Description** (App Store and Google Play)
<!-- limit=4000 unit=chars -->
```text
Copas (Hearts), o clássico jogo de cartas para quatro, bem feito: você contra três bots, no seu celular, sem nada no caminho.

Passe três cartas. Siga o naipe. Fuja da dama de espadas e de todas as copas que puder — ou leve todas e atire na lua. Vence a menor pontuação.

SEM ANÚNCIOS, SEM CADASTRO
Não há anúncios, contas, sequências diárias nem fichas para comprar. Você abre, joga uma mão e fecha. Funciona offline, e nada sobre você sai do seu celular.

BOTS COM NOME
Seus adversários são amantes famosos — Romeo, Cyrano, Casanova, Don Juan e dezenas de outros — e cada um joga com seu próprio temperamento. Um não consegue segurar a dama; outro espera o momento certo; outro vai atrás da lua com uma mão que ninguém mais tentaria. Por baixo, todos jogam o mesmo jogo forte, e cada um foi medido, não adivinhado.

ELE DIZ POR QUÊ
Toque numa carta que você não pode jogar e ele diz qual regra impediu a jogada, em vez de simplesmente recusar.

AS REGRAS
• Quatro jogadores, treze cartas cada um.
• Passe três cartas: para a esquerda, para a direita, para quem está à frente e, depois, nenhuma.
• O dois de paus começa. Siga o naipe sempre que puder.
• Não se pode puxar copas até que uma tenha sido jogada.
• Cada copa vale um ponto; a dama de espadas, treze.
• Quem leva todos os 26 pontos atira na lua: os outros ficam com eles.
• O jogo acaba quando alguém chega a 50. Vence a menor pontuação.

QUALQUER TELA
Celular ou tablet, em pé ou deitado: a mesa se ajusta ao espaço que tem. Respeita o ajuste "Reduzir Movimento" do seu aparelho.

SUAS PARTIDAS SÃO SUAS
Suas partidas recentes ficam guardadas no celular, e o seu perfil faz as contas: partidas, vitórias, melhor resultado. Nada é enviado.

CÓDIGO ABERTO
Open Hearts tem licença MIT e é desenvolvido abertamente. Leia o motor de regras, leia os bots, abra uma issue: github.com/bfulton/open-hearts

O aplicativo está em português, inglês, espanhol, alemão e francês.
```
Count: 1928 of 4000 characters

**Google Play — Title**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Copas
```
Count: 18 of 30 characters

**Short description**
<!-- limit=80 unit=chars -->
```text
Copas contra três bots com nome. Sem anúncios, sem cadastro, funciona offline.
```
Count: 78 of 80 characters

**Captions**
<!-- limit=6 unit=words -->
```text
Copas, do jeito que você lembra
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Passe três. Fuja da dama.
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Toque numa carta, aprenda a regra
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Atire na lua
```
Count: 3 of 6 words

<!-- limit=6 unit=words -->
```text
Rivais com nome e temperamento
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Qualquer tela, em pé ou deitado
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Sem anúncios. Nada sai do celular.
```
Count: 6 of 6 words

### Deutsch

**App Store — Name**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Kartenspiel
```
Count: 24 of 30 characters

**Subtitle**
<!-- limit=30 unit=chars -->
```text
Schwarze Lady, ohne Werbung
```
Count: 27 of 30 characters

**Keywords**
<!-- limit=100 unit=bytes -->
```text
herzeln,pik,dame,mond,karten,stiche,klassisch,strategie,offline,bots,regeln,lernen,solo,whist
```
Count: 93 of 100 bytes (93 characters)

**Promotional text**
<!-- limit=170 unit=chars -->
```text
Hearts, wie du es kennst: drei Karten weitergeben, der Pik-Dame ausweichen, den Mond schießen. Drei Bots mit Namen, keine Werbung, nichts zu kaufen, alles offline.
```
Count: 163 of 170 characters

**Description** (App Store and Google Play)
<!-- limit=4000 unit=chars -->
```text
Hearts, das klassische Kartenspiel für vier, richtig gemacht: du gegen drei Bots, auf deinem Handy, ohne dass etwas im Weg steht.

Drei Karten weitergeben. Farbe bedienen. Der Pik-Dame und jedem Herz ausweichen, das sich vermeiden lässt – oder alle nehmen und den Mond schießen. Die niedrigste Punktzahl gewinnt.

KEINE WERBUNG, KEINE ANMELDUNG
Keine Werbung, keine Konten, keine täglichen Serien, keine Chips zum Kaufen. Du öffnest es, spielst eine Runde und schließt es wieder. Es funktioniert offline, und nichts über dich verlässt dein Handy.

BOTS MIT NAMEN
Deine Gegner sind berühmte Liebende – Romeo, Cyrano, Casanova, Don Juan und Dutzende mehr – und jeder spielt mit eigenem Temperament. Einer kann die Dame nicht halten, ein anderer wartet auf den richtigen Moment, ein dritter versucht den Mond mit einer Hand, mit der es sonst niemand wagen würde. Darunter spielen alle dasselbe starke Spiel, und jeder ist gemessen, nicht geraten.

ES SAGT DIR, WARUM
Tippe auf eine Karte, die du nicht spielen darfst, und es sagt dir, welche Regel dich aufhält, statt sie einfach abzulehnen.

DIE REGELN
• Vier Spieler, je dreizehn Karten.
• Drei Karten weitergeben: nach links, nach rechts, nach gegenüber, dann gar nicht.
• Die Kreuz-Zwei spielt aus. Farbe bedienen, wann immer es geht.
• Herz darf erst ausgespielt werden, wenn schon eines gefallen ist.
• Jedes Herz zählt einen Punkt, die Pik-Dame dreizehn.
• Wer alle 26 nimmt, schießt den Mond: Dann bekommen sie alle anderen.
• Das Spiel endet, wenn jemand 50 erreicht. Die niedrigste Punktzahl gewinnt.

JEDER BILDSCHIRM
Handy oder Tablet, hochkant oder quer: Der Tisch richtet sich nach dem Platz, den er hat. Die Einstellung „Bewegung reduzieren“ deines Geräts wird beachtet.

DEINE SPIELE GEHÖREN DIR
Deine letzten Spiele werden auf deinem Handy gespeichert, und dein Profil zählt sie zusammen: Spiele, Siege, bestes Ergebnis. Nichts wird hochgeladen.

OPEN SOURCE
Open Hearts steht unter der MIT-Lizenz und wird offen entwickelt. Lies die Regel-Engine, lies die Bots, eröffne ein Issue: github.com/bfulton/open-hearts

Die App gibt es auf Deutsch, Englisch, Spanisch, Portugiesisch und Französisch.
```
Count: 2157 of 4000 characters

**Google Play — Title**
<!-- limit=30 unit=chars -->
```text
Open Hearts: Kartenspiel
```
Count: 24 of 30 characters

**Short description**
<!-- limit=80 unit=chars -->
```text
Hearts gegen drei Bots mit Namen. Keine Werbung, keine Anmeldung, auch offline.
```
Count: 79 of 80 characters

**Captions**
<!-- limit=6 unit=words -->
```text
Hearts, wie du es kennst
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Drei weitergeben. Der Dame ausweichen.
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Karte antippen, Regel lernen
```
Count: 4 of 6 words

<!-- limit=6 unit=words -->
```text
Den Mond schießen
```
Count: 3 of 6 words

<!-- limit=6 unit=words -->
```text
Gegner mit Namen und Temperament
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Jeder Bildschirm, hochkant oder quer
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Keine Werbung. Nichts verlässt dein Handy.
```
Count: 6 of 6 words

### Français

**App Store — Name** — with the space French puts before a colon.
<!-- limit=30 unit=chars -->
```text
Open Hearts : Dame de pique
```
Count: 27 of 30 characters

**Subtitle**
<!-- limit=30 unit=chars -->
```text
Jeu de cartes sans publicité
```
Count: 28 of 30 characters

**Keywords**
<!-- limit=100 unit=bytes -->
```text
coeur,cœur,lune,plis,chelem,classique,stratégie,hors,ligne,bots,règles,apprendre,solo,whist
```
Count: 94 of 100 bytes (91 characters)

**Promotional text**
<!-- limit=170 unit=chars -->
```text
La Dame de pique comme dans vos souvenirs : passez trois cartes, évitez la dame, tentez le grand chelem. Trois bots avec un nom, sans publicité, rien à acheter.
```
Count: 160 of 170 characters

**Description** (App Store and Google Play)
<!-- limit=4000 unit=chars -->
```text
La Dame de pique (Hearts), le grand classique des jeux de cartes à quatre, bien fait : vous contre trois bots, sur votre téléphone, sans rien entre vous et la partie.

Passez trois cartes. Fournissez à la couleur. Évitez la dame de pique et tous les cœurs possibles — ou ramassez tout et faites le grand chelem. Le score le plus bas l'emporte.

SANS PUBLICITÉ, SANS INSCRIPTION
Pas de publicité, pas de compte, pas de séries quotidiennes, pas de jetons à acheter. Vous ouvrez, vous jouez une donne, vous refermez. Il fonctionne hors ligne, et rien de ce qui vous concerne ne quitte votre téléphone.

DES BOTS QUI ONT UN NOM
Vos adversaires sont des amants célèbres — Romeo, Cyrano, Casanova, Don Juan et des dizaines d'autres — et chacun joue avec son tempérament. L'un ne sait pas garder la dame ; un autre attend son heure ; un autre tente le grand chelem avec une main que personne d'autre n'oserait jouer. Au fond, tous jouent le même jeu solide, et chacun a été mesuré, pas deviné.

IL VOUS DIT POURQUOI
Touchez une carte que vous ne pouvez pas jouer : il vous dit quelle règle vous en empêche, au lieu de simplement refuser.

LES RÈGLES
• Quatre joueurs, treize cartes chacun.
• On passe trois cartes : à gauche, à droite, en face, puis aucune.
• Le deux de trèfle entame. On fournit à la couleur chaque fois qu'on le peut.
• On ne peut pas entamer à cœur tant qu'aucun cœur n'a été joué.
• Chaque cœur vaut un point ; la dame de pique, treize.
• Qui ramasse les 26 points fait le grand chelem : ce sont les autres qui les prennent.
• La partie s'arrête quand quelqu'un atteint 50. Le score le plus bas gagne.

TOUS LES ÉCRANS
Téléphone ou tablette, en portrait ou en paysage : la table s'adapte à la place qu'elle a. Le réglage « Réduire les animations » de votre appareil est respecté.

VOS PARTIES VOUS APPARTIENNENT
Vos parties récentes sont gardées sur votre téléphone, et votre profil en fait le compte : parties, victoires, meilleur score. Rien n'est envoyé.

OPEN SOURCE
Open Hearts est sous licence MIT et développé au grand jour. Lisez le moteur de règles, lisez les bots, ouvrez un ticket : github.com/bfulton/open-hearts

L'application est en français, anglais, espagnol, portugais et allemand.
```
Count: 2212 of 4000 characters

**Google Play — Title**
<!-- limit=30 unit=chars -->
```text
Open Hearts : Dame de pique
```
Count: 27 of 30 characters

**Short description**
<!-- limit=80 unit=chars -->
```text
La Dame de pique contre trois bots. Sans pub, sans compte, hors ligne.
```
Count: 70 of 80 characters

**Captions**
<!-- limit=6 unit=words -->
```text
La Dame de pique, comme avant
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Passez trois. Évitez la dame.
```
Count: 5 of 6 words

<!-- limit=6 unit=words -->
```text
Touchez une carte, apprenez la règle
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Faites le grand chelem
```
Count: 4 of 6 words

<!-- limit=6 unit=words -->
```text
Des rivaux qui ont du caractère
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Tous les écrans, tous les sens
```
Count: 6 of 6 words

<!-- limit=6 unit=words -->
```text
Sans pub. Tout reste chez vous.
```
Count: 6 of 6 words
