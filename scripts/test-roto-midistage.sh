#!/bin/bash
# 物理 MIDI / Serial を開かない Swift ↔ Rust loopback 検証。
# Package.swift の固定版と同じ gear_fixture を隔離した build/state で使う。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$repo_dir/ladyland"
fixture_target="$package_dir/.build/roto-fixture-target"
swift package --package-path "$package_dir" resolve
lnx_dir="$package_dir/.build/checkouts/lnx"
expected_revision="$(python3 - "$package_dir/Package.resolved" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    pins = json.load(file)["pins"]
print(next(pin["state"]["revision"] for pin in pins if pin["identity"] == "lnx"))
PY
)"
actual_revision="$(git -C "$lnx_dir" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
    echo "lnx fixture revision mismatch: $actual_revision != $expected_revision" >&2
    exit 1
fi
git -C "$lnx_dir" diff --exit-code --quiet HEAD --
echo "lnx fixture revision: $actual_revision"
(
    cd "$lnx_dir"
    if [[ -f rust-toolchain.toml ]]; then
        rust_toolchain="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' rust-toolchain.toml)"
    else
        rust_toolchain="stable"
    fi
    [[ -n "$rust_toolchain" ]] || { echo "upstream Rust toolchain is missing" >&2; exit 1; }
    locked_flag=""
    [[ -f Cargo.lock ]] && locked_flag="--locked"
    rustup run --install "$rust_toolchain" cargo build ${locked_flag:+$locked_flag} -j 2 -p lnx-server \
        --example gear_fixture --target-dir "$fixture_target"
)
LNX_TEST_SERVER="$fixture_target/debug/examples/gear_fixture" \
    swift test --package-path "$package_dir" --jobs 2 --filter 'RotoMidistage|rotoSession|rotoRegistration'
