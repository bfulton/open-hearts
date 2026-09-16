//! Native run: `cargo run --release [transfers]`.
//!
//! Prints where the time goes and what a hand of doc 04's circuit would
//! cost at this rate.

use std::time::Instant;

/// One bot-held seat for one hand (packages/engine/tool/circuit_count.dart).
const GATES: usize = 53_726;

fn main() {
    let m: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1 << 20);
    let start = Instant::now();
    let now = || start.elapsed().as_secs_f64() * 1000.0;

    // Once to warm, then the run that counts.
    let _ = ot_bench::extend(1 << 14, 1, &now);
    let c = ot_bench::extend(m, 2, &now);
    let all = c.expand + c.transpose + c.check + c.hash;
    let per = |ms: f64| ms * 1e6 / m as f64; // nanoseconds

    println!("{m} extended transfers, one core\n");
    println!("  expand      {:8.1} ms   {:7.3} ns each", c.expand, per(c.expand));
    println!("  transpose   {:8.1} ms   {:7.3} ns each", c.transpose, per(c.transpose));
    println!("  check       {:8.1} ms   {:7.3} ns each", c.check, per(c.check));
    println!("  hash        {:8.1} ms   {:7.3} ns each", c.hash, per(c.hash));
    println!("  all         {:8.1} ms   {:7.3} ns each", all, per(all));
    println!("\n  on the wire {:8} bytes  {:7.1} bytes each", c.sent, c.sent as f64 / m as f64);
    // The check is shift-and-xor here; a core with a carry-less
    // multiply instruction does that part in a few nanoseconds.
    let lean = c.expand + c.transpose + c.hash;
    println!("  without the check, {:7.1} ns each", per(lean));
    println!("\nfor a seat's {GATES} AND gates, at one transfer a gate:");
    println!("  {:.0} ms as measured, {:.0} ms with the check at hardware speed, {:.0} KB on the wire",
        per(all) * GATES as f64 / 1e6,
        per(lean) * GATES as f64 / 1e6,
        c.sent as f64 / m as f64 * GATES as f64 / 1024.0);

    triples(
        std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(1 << 12),
        std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(ot_bench::triple::BUCKET),
    );
    decision(
        &std::env::args().nth(4).unwrap_or_else(|| "bot.circuit".into()),
        std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(ot_bench::triple::BUCKET),
    );
}

/// The authentication on top, which is what a gate actually costs.
fn triples(n: usize, bucket: usize) {
    let start = Instant::now();
    let now = || start.elapsed().as_secs_f64() * 1000.0;
    let _ = ot_bench::triple::triples(256, bucket, 1, &now);
    let c = ot_bench::triple::triples(n, bucket, 2, &now);
    let all = c.abits + c.haand + c.check + c.bucket;
    let per = |ms: f64| ms * 1e6 / n as f64; // nanoseconds
    let bytes = c.bits as f64 / 8.0 / n as f64;

    println!("\n{n} authenticated AND triples, bucket of {bucket}, one core\n");
    println!("  the transfers under them {:8.1} ms  {:9.0} ns each", c.abits, per(c.abits));
    println!("  the cross terms          {:8.1} ms  {:9.0} ns each", c.haand, per(c.haand));
    println!("  the leaky check          {:8.1} ms  {:9.0} ns each", c.check, per(c.check));
    println!("  bucketing                {:8.1} ms  {:9.0} ns each", c.bucket, per(c.bucket));
    println!("  all of it                {:8.1} ms  {:9.0} ns each", all, per(all));
    let lean = all - c.abits_check;
    println!("  without the KOS check    {:8.1} ms  {:9.0} ns each", lean, per(lean));
    println!("\n  on the wire {:9.0} bytes each — {:.0} the transfers, {:.0} the check — {} transfers and {} block cipher calls a triple",
        bytes, c.abit_bits as f64 / 8.0 / n as f64, (c.bits - c.abit_bits) as f64 / 8.0 / n as f64, c.transfers / n, c.aes / n);
    println!("\nfor a seat's {GATES} AND gates, one triple a gate:");
    println!("  {:.1} s as measured, {:.1} s without the KOS check, {:.1} MB on the wire, {:.0} bytes a gate",
        per(all) * GATES as f64 / 1e9,
        per(lean) * GATES as f64 / 1e9,
        bytes * GATES as f64 / 1048576.0,
        bytes);
}

/// And the whole of a bot's decision: the policy garbled, over a hand
/// neither party can see.
fn decision(path: &str, bucket: usize) {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            println!("\nno circuit at {path}: {e}");
            println!("  cd packages/engine && dart run tool/circuit_dump.dart 1 20 > ../../measurements/ot/bot.circuit");
            return;
        }
    };
    let net = ot_bench::garble::Netlist::parse(&text);
    let start = Instant::now();
    let now = || start.elapsed().as_secs_f64() * 1000.0;
    let (out, c) = ot_bench::garble::compute(&net, &net.values, bucket, 2, &now);
    assert_eq!(out, net.expect, "the garbled policy picks what the bot picks");
    let all = c.preprocess + c.garble + c.evaluate;
    let bytes = c.bits as f64 / 8.0;

    println!("\none decision of the bot, garbled, bucket of {bucket}, one core\n");
    println!("  {} AND gates, {} wires, {} inputs, {} outputs", c.ands, net.wires, net.inputs.len(), net.outputs.len());
    println!("  the triples and the bits {:8.1} ms", c.preprocess);
    println!("  garbling                 {:8.1} ms", c.garble);
    println!("  evaluating               {:8.1} ms", c.evaluate);
    println!("  all of it                {:8.1} ms", all);
    println!(
        "\n  on the wire {:.2} MB — {:.2} the preprocessing, {:.2} the tables and the rest",
        bytes / 1048576.0,
        c.preprocess_bits as f64 / 8.0 / 1048576.0,
        (c.bits - c.preprocess_bits) as f64 / 8.0 / 1048576.0,
    );
    println!("  {:.0} bytes a gate, {} block cipher calls", bytes / c.ands as f64, c.aes);
    println!("\na hand is a pass and thirteen plays; at this play's size that is");
    println!("  {:.1} MB and {:.1} s for thirteen of them, before the pass", 13.0 * bytes / 1048576.0, 13.0 * all / 1000.0);
}
