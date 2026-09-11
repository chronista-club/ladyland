#!/bin/bash
# 検証マトリクスの正典（2026-08-09 制定。CI とローカルが同じものを叩く）。
#
#   scripts/test-matrix.sh          # フルマトリクス（CI / 最終確認）
#   scripts/test-matrix.sh --quick  # モード 1 のみ（レーンの push 前チェック）
#
# ⚠️ 「3 モード」の定義はここが唯一の置き場。手書きで env を並べると
#    フラグが増えるたびにズレる（2026-08-08 に実際にズレた）。
#
# ⚠️ 退避路フラグ（既定 on、`=0` で切る）を足したら **ESCAPE_HATCHES にも足す**。
#    CLAUDE.md「🚨 会場での退避路」と同期させること。
#    `=1` で入れる opt-in（SELFTEST / BENCH / ROTO_QUIET など）は対象外 —
#    あれは既定 off が正で、マトリクスは既定挙動と退避挙動の両方を見る。
set -euo pipefail

cd "$(dirname "$0")/../ladyland"

# 退避路すべて =0（「確実に鳴る側」へ全部倒した状態でもテストが通ること）
ESCAPE_HATCHES=(
    LADYLAND_BUS_FOLLOW=0
    LADYLAND_MAIN_LCD=0
    LADYLAND_FILL_EMPTY=0
    LADYLAND_PARK_EMPTY_KNOBS=0
    LADYLAND_RENDER_STATS=0
    LADYLAND_KEYSTAGE_CONNECT=0
    LADYLAND_KEYSTAGE_ASSIGNABLE=0
    LADYLAND_KEYSTAGE_RELEASE=0
    LADYLAND_FIELD=0
    LADYLAND_FIELD_SPAWN=0
)

echo "── モード 1/4: swift test（既定）──"
swift test

if [[ "${1:-}" == "--quick" ]]; then
    echo "── quick: モード 1 のみで終了 ──"
    exit 0
fi

echo "── モード 2/4: swift test（退避路すべて =0）──"
env "${ESCAPE_HATCHES[@]}" swift test

echo "── モード 3/4: swift test -c release ──"
swift test -c release

echo "── モード 4/4: swift build -c release ──"
swift build -c release

echo "── フルマトリクス完了 ──"
