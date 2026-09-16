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
}
