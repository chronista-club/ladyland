#!/bin/bash
# 物理 MIDI / Serial を開かない Swift ↔ Rust loopback 検証。
# Package.swift の固定版と同じ protocol_fixture を隔離した build/state で使う。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$repo_dir/ladyland"
fixture_target="$package_dir/.build/roto-fixture-target"
swift package --package-path "$package_dir" resolve
midistage_dir="$package_dir/.build/checkouts/midistage"
expected_revision="$(python3 - "$package_dir/Package.resolved" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    pins = json.load(file)["pins"]
print(next(pin["state"]["revision"] for pin in pins if pin["identity"] == "midistage"))
PY
)"
actual_revision="$(git -C "$midistage_dir" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
    echo "midistage fixture revision mismatch: $actual_revision != $expected_revision" >&2
    exit 1
fi
git -C "$midistage_dir" diff --exit-code --quiet HEAD --
echo "midistage fixture revision: $actual_revision"
(
    cd "$midistage_dir"
    # upstream rust-toolchain.toml の版を使用。runner の cargo shim / mise 設定は不要。
    rust_toolchain="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' rust-toolchain.toml)"
    [[ -n "$rust_toolchain" ]] || { echo "upstream Rust toolchain is missing" >&2; exit 1; }
    rustup run --install "$rust_toolchain" cargo build --locked -j 2 -p midistaged \
        --example protocol_fixture --target-dir "$fixture_target"
)
MIDISTAGE_TEST_SERVER="$fixture_target/debug/examples/protocol_fixture" \
    swift test --package-path "$package_dir" --jobs 2 --filter 'RotoMidistage|rotoSession|rotoRegistration'
