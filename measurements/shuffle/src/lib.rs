//! Times one verifiable deal of 52 cards, the way docs/03-fair-deal.md
//! describes it: four players each shuffle-and-remask the deck with a
//! proof, everyone verifies every proof, and cards are opened with
//! reveal tokens. The protocol is Barnett–Smart with a Bayer–Groth
//! shuffle argument, from geometryxyz/mental-poker, on the Starknet
//! curve. Nothing here is the game's cryptography; it is the reference
//! implementation, timed, so the design knows what a deal costs.
//!
//! Built natively it prints; built for wasm32-unknown-unknown it imports
//! `now` and `report` from the host, so the same code runs in a browser
//! with no glue library — bench.html and bench.mjs are the hosts.

use ark_ff::UniformRand;
use ark_std::One;
use barnett_smart_card_protocol::discrete_log_cards;
use barnett_smart_card_protocol::BarnettSmartProtocol;
use proof_essentials::to_bytes;
use proof_essentials::utils::permutation::Permutation;
use proof_essentials::utils::rand::sample_vector;
use rand::SeedableRng;
use rand_chacha::ChaCha20Rng;

type Curve = starknet_curve::Projective;
type Scalar = starknet_curve::Fr;
type CardProtocol = discrete_log_cards::DLCards<Curve>;
type Card = discrete_log_cards::Card<Curve>;
type MaskedCard = discrete_log_cards::MaskedCard<Curve>;

pub const DECK: usize = 52;
const PLAYERS: usize = 4;
const HAND: usize = 13;

/// Every step of one deal, in milliseconds, as one player experiences
/// it: their own work plus verifying everyone else's.
#[derive(Debug, Default, Clone)]
pub struct Timings {
    pub setup: f64,
    pub keygen: f64,
    pub key_proof_verify: f64,
    pub mask_deck: f64,
    /// One player's shuffle with its proof.
    pub shuffle_prove: f64,
    /// Verifying one other player's shuffle proof.
    pub shuffle_verify: f64,
    /// One reveal token with its proof.
    pub reveal_token: f64,
    /// Unmasking one card from four tokens, their proofs checked.
    pub unmask: f64,
}

impl Timings {
    /// What one player computes for a full deal: their shuffle, three
    /// verifications, the 39 tokens they owe the other seats, and
    /// opening their 13 cards (which checks the 39 tokens they receive).
    pub fn per_player_deal(&self) -> f64 {
        self.shuffle_prove
            + (PLAYERS - 1) as f64 * self.shuffle_verify
            + (PLAYERS - 1) as f64 * HAND as f64 * self.reveal_token
            + HAND as f64 * self.unmask
    }

    /// The critical path from "sit" to "cards in hand": four shuffles
    /// one after another, each verified by the next shuffler before
    /// they start; then tokens, which everyone computes at once, and the
    /// opening. Network time is not in here.
    pub fn table_deal_latency(&self) -> f64 {
        PLAYERS as f64 * self.shuffle_prove
            + (PLAYERS - 1) as f64 * self.shuffle_verify
            + (PLAYERS - 1) as f64 * HAND as f64 * self.reveal_token
            + HAND as f64 * self.unmask
    }
}

/// Runs one deal, timing each step with `now` (milliseconds).
pub fn run(seed: u64, mut now: impl FnMut() -> f64) -> Timings {
    let rng = &mut ChaCha20Rng::seed_from_u64(seed);
    let mut t = Timings::default();
    let (m, n) = (2, 26);

    let t0 = now();
    let pp = CardProtocol::setup(rng, m, n).unwrap();
    t.setup = now() - t0;

    let t0 = now();
    let mut keys = Vec::new();
    for i in 0..PLAYERS {
        let (pk, sk) = CardProtocol::player_keygen(rng, &pp).unwrap();
        let name = to_bytes![format!("player{i}").as_bytes()].unwrap();
        let proof = CardProtocol::prove_key_ownership(rng, &pp, &pk, &sk, &name).unwrap();
        keys.push((pk, sk, proof, name));
    }
    t.keygen = (now() - t0) / PLAYERS as f64;

    let t0 = now();
    let key_info: Vec<_> = keys.iter().map(|k| (k.0, k.2, k.3.clone())).collect();
    let joint_pk = CardProtocol::compute_aggregate_key(&pp, &key_info).unwrap();
    t.key_proof_verify = now() - t0;

    let plaintexts: Vec<Card> = (0..DECK).map(|_| Card::rand(rng)).collect();
    let t0 = now();
    let deck: Vec<MaskedCard> = plaintexts
        .iter()
        .map(|c| CardProtocol::mask(rng, &pp, &joint_pk, c, &Scalar::one()).unwrap().0)
        .collect();
    t.mask_deck = now() - t0;

    let mut current = deck;
    let mut prove = 0.0;
    let mut verify = 0.0;
    for _ in 0..PLAYERS {
        let permutation = Permutation::new(rng, DECK);
        let factors: Vec<Scalar> = sample_vector(rng, DECK);
        let t0 = now();
        let (next, proof) =
            CardProtocol::shuffle_and_remask(rng, &pp, &joint_pk, &current, &factors, &permutation)
                .unwrap();
        prove += now() - t0;
        let t0 = now();
        CardProtocol::verify_shuffle(&pp, &joint_pk, &current, &next, &proof).unwrap();
        verify += now() - t0;
        current = next;
    }
    t.shuffle_prove = prove / PLAYERS as f64;
    t.shuffle_verify = verify / PLAYERS as f64;

    // Deal seat 0 its thirteen cards: every player computes a token for
    // each, seat 0 verifies the others' and unmasks.
    let mut token_time = 0.0;
    let mut unmask_time = 0.0;
    let mut opened = 0;
    for card in current.iter().take(HAND) {
        let mut tokens = Vec::new();
        for (pk, sk, _, _) in &keys {
            let t0 = now();
            let (token, proof) = CardProtocol::compute_reveal_token(rng, &pp, sk, pk, card).unwrap();
            token_time += now() - t0;
            tokens.push((token, proof, *pk));
        }
        // unmask checks every token's proof before combining them.
        let t0 = now();
        let plain = CardProtocol::unmask(&pp, &tokens, card).unwrap();
        unmask_time += now() - t0;
        assert!(plaintexts.contains(&plain), "unmasked to a card that was never dealt");
        opened += 1;
    }
    t.reveal_token = token_time / (opened * PLAYERS) as f64;
    t.unmask = unmask_time / opened as f64;
    t
}

#[cfg(target_arch = "wasm32")]
mod no_entropy {
    use getrandom::{register_custom_getrandom, Error};
    fn none(_: &mut [u8]) -> Result<(), Error> {
        Err(Error::UNSUPPORTED)
    }
    register_custom_getrandom!(none);
}

#[cfg(target_arch = "wasm32")]
mod host {
    // Imported from the host by name: newer linkers no longer leave an
    // undefined symbol to be an import of its own accord.
    #[link(wasm_import_module = "env")]
    extern "C" {
        pub fn now() -> f64;
        pub fn report(id: u32, ms: f64);
    }
}

/// Entry point for the browser host: runs one deal and reports each
/// timing by id (see bench.html for the ids).
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn bench(seed: u64) {
    let t = run(seed, || unsafe { host::now() });
    let fields = [
        t.setup,
        t.keygen,
        t.key_proof_verify,
        t.mask_deck,
        t.shuffle_prove,
        t.shuffle_verify,
        t.reveal_token,
        t.unmask,
        t.per_player_deal(),
        t.table_deal_latency(),
    ];
    for (i, ms) in fields.iter().enumerate() {
        unsafe { host::report(i as u32, *ms) };
    }
}
