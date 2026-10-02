# Hearts App — Launch Punch List

## Positioning
- Free solo play, forever. No ads, no tracking, no sign-up.
- Multiplayer: $5–10/year, covers server costs.
- Open-source the code so players can audit fairness (especially the shuffle/RNG).

## Pre-launch (blockers)
- [ ] Security pass on server side (timebox to one week).
- [ ] Open-source readiness: no secrets or anti-cheat logic in published code.
- [ ] Document RNG: cryptographically secure source, properly seeded.
- [ ] Crash reporting (Sentry or Crashlytics).
- [ ] Privacy-friendly product analytics: first-session drop-off, D1/D7 retention. No ad SDKs.
- [ ] Server observability via Workers Analytics Engine / Tail Workers; watch Durable Object storage costs.
- [ ] In-app feedback path ("tell us what's broken") before any review prompt.
- [ ] Remote config served from a Worker:
  - AI difficulty tuning
  - Multiplayer server selection
  - Multiplayer kill switch
  - Maintenance banner
  - "Please update" nudge
  - Pricing / paid-tier visibility
- [ ] Availability alerting: check from outside, every few minutes, that the site, `/api/config`, a signed checkout and relay.openhearts.game answer, and email when one does not. A checkout was down for about an hour on 2 October (an expired Stripe key still in the live deployment) and nothing said so.
- [ ] Graceful degradation when the server is down.
- [ ] Verify offline mode in airplane mode (no infinite spinners).
- [ ] Privacy policy + App Store privacy labels stating no data collected.
- [ ] Payments: Apple IAP on iOS, Stripe on web. Anonymous purchase stored locally; optional "link account" (Sign in with Apple/Google) for cross-device.

## Launch marketing
- [ ] App Store optimization: plain, searchable title (e.g. "Hearts: Classic Card Game"), strong subtitle and screenshots.
- [ ] Apple Search Ads (Advanced), ~$50 test budget on day one.
  - Keywords: hearts, hearts card game, hearts free, play hearts, hearts online, card games
  - Competitors: hearts plus, hearts++
  - Adjacent: spades, euchre, solitaire
- [ ] Facebook ads targeting 65+, card game / solitaire / bridge interests.
- [ ] Programmatic networks (AdMob, Unity Ads; later AppLovin, ironSource) targeting casual card-game inventory. Expect ~$1–3 per install.
- [ ] Use the Flutter web build as a zero-install landing link for ads.

## Fast follow
- [ ] Localization: Spanish and Portuguese first, then German and French.
- [ ] Stats graphs: average score over last 20 games, Queen of Spades taken, moons shot, moons blocked.
- [ ] VoiceOver polish; test by having an LLM play a hand blind via the accessibility tree.

## Later
- [ ] Apple editorial featuring submission.
- [ ] Open-source repo cleanup and promotion.
- [ ] Press outreach to senior-tech / accessibility outlets (e.g. AARP).
- [ ] Senior-center kit mailed to activity directors.
- [ ] Reddit (r/cardgames) and Hearts-player communities.

## Parked
- Asian-language localization
- YouTube strategy-channel sponsorships
- Apple Watch, Vision Pro, Mac Catalyst
- Tournaments, leaderboards, extended achievements
- Friend lists, chat

## Already done
- Responsive layout (phone + iPad)
- Web version (shared Flutter codebase)
- Bot takes over when a multiplayer player quits
- Frictionless start
- Basic score tracking
