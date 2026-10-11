# deal

The verifiable deal: the Rust crate in `crypto/deal`, bound for the Dart
VM over FFI and for the browser over its wasm, behind one interface.
What it does and why is in
[the fair deal](../../docs/explanation/fair-deal.md).

```bash
(cd ../../crypto/deal && cargo build --release)  # the library the VM loads
dart test
```
