//! Native run of the deal benchmark: `cargo run --release`.

use std::time::Instant;

fn main() {
    let start = Instant::now();
    let runs = 3;
    let mut last = None;
    for seed in 0..runs {
        let t = shuffle_bench::run(seed, || start.elapsed().as_secs_f64() * 1000.0);
        last = Some(t);
    }
    let t = last.unwrap();
    println!("{t:#?}");
    println!("per-player deal work : {:.0} ms", t.per_player_deal());
    println!("table deal latency   : {:.0} ms", t.table_deal_latency());
}
