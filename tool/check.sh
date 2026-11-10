#!/usr/bin/env bash
set -euo pipefail
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
cargo fmt --manifest-path rust/Cargo.toml --check
cargo test --manifest-path rust/Cargo.toml --features server --locked
cargo clippy --manifest-path rust/Cargo.toml --features server --all-targets --locked -- -D warnings
