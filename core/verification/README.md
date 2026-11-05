# Pure-rule verification

This crate imports `crdt.rs`, `rules.rs` and `tagmodel.rs` directly from the production
source tree. It avoids compiling SQLite, image codecs, networking and the FFI just
to verify pure rules. It does **not** verify those omitted modules or the SQL implementation.

From the repository root, with Cargo/Kani on PATH:

```sh
export CARGO_TARGET_DIR="$(python3 scripts/apply.py where cache)/kani"
cargo kani --manifest-path core/verification/Cargo.toml --lib --default-unwind 12
```

Harness-specific unwind annotations still apply. Keep unwinding assertions enabled:
an insufficient bound is a failed verification, not a proof.

For selected harnesses with the existing process-tree memory/time guard:

```sh
scripts/kani_guard.sh channel_nonces_never_wrap_or_repeat missing_range_exact
```

The corresponding implementation checks are in `core/tests/model_fidelity.rs`,
`core/tests/model_based.rs`, `core/tests/ai_queue.rs`, `core/tests/sync_safety.rs`,
and the encrypted channel tests in `core/src/sync.rs`. Passing bounded rules and
randomized tests does not establish end-to-end crash safety or distributed liveness.
