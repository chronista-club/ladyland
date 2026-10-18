#!/bin/bash
# 物理 MIDI / Serial を開かない Swift ↔ Rust loopback 検証。
# Package.swift の固定版と同じ protocol_fixture を隔離した build/state で使う。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$repo_dir/ladyland"
fixture_target="$package_dir/.build/roto-fixture-target"
swift package --package-path "$package_dir" resolve
(
    cd "$package_dir/.build/checkouts/midistage"
    cargo build --locked -j 2 -p midistaged --example protocol_fixture --target-dir "$fixture_target"
)
MIDISTAGE_TEST_SERVER="$fixture_target/debug/examples/protocol_fixture" \
    swift test --package-path "$package_dir" --jobs 2 --filter 'RotoMidistage|rotoSession|rotoRegistration'
