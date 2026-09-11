#!/usr/bin/env bash
#
# ladyland.app を組み立てる（mako 要望 2026-08-02「Mac App として、
# アイコン付きで起動したい」）。
#
# SPM は .app バンドルを作れないので、release バイナリに Info.plist と
# AppIcon を着せてここで組む。Xcode プロジェクトは導入しない —
# `swift build` / `swift test` の作法を変えないため。
#
# バンドル化で実際に変わること（見た目だけの話ではない）:
#   - Dock / Cmd+Tab にアイコンと名前が出る
#   - **⌘Q と Finder からの終了で willTerminate が確実に飛ぶ**
#     （unbundled バイナリは AppleScript quit も効かず、TERM 落ちで
#      状態を失った実例がある。design/06 §8）
#   - 将来 UTI 宣言（.kdl スナップショットの関連付け）を載せられる
#
# 使い方:
#   scripts/build-app.sh              # ビルドして ./dist/Ladyland.app を作る
#   scripts/build-app.sh --install    # さらに /Applications へ配置
#   scripts/build-app.sh --run        # 作ってそのまま起動
#   scripts/build-app.sh --dist       # 配布物を作る（公証 + staple + DMG）
#   scripts/build-app.sh --reinstall  # 開発の輪: 終了 → ビルド → 差し替え → 起動
#
# --reinstall は「今動いているのを正しく終わらせてから入れ替える」ための道。
# ⚠️ kill ではなく **AppleScript quit** を使う — willTerminate が走らないと
# 終了時保存（ラック構成・音色・ウィンドウ配置）が落ちる（design/06 §8）。
# プロセスが消えるのを待ってから置き換える（走っている .app を rm すると壊す）。
#
# 配布（他の Mac へ配る）には**公証**が要る。ダウンロード / AirDrop で付く
# quarantine 属性を Gatekeeper が見るため、Developer ID 署名だけでは
# 「開発元を確認できません」で止まる。公証 → staple すれば、相手が
# オフラインでも検証が通る。
#
# 公証には資格情報の登録が一度だけ必要（対話。ここでは実行しない）:
#   xcrun notarytool store-credentials "ladyland" \
#       --apple-id <Apple ID> --team-id 3EQKG4B352 --password <アプリ用パスワード>
#   ※ アプリ用パスワードは account.apple.com → サインインとセキュリティ で発行
#
# 対象は **arm64 のみ**（mako 裁定 2026-08-02）。Intel Mac では動かない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/ladyland"
DIST="$REPO_ROOT/dist"
APP="$DIST/Ladyland.app"
CONTENTS="$APP/Contents"
NOTARY_PROFILE="${LADYLAND_NOTARY_PROFILE:-ladyland}"

INSTALL=0
RUN=0
MAKE_DIST=0
REINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        --dist) MAKE_DIST=1 ;;
        --reinstall) REINSTALL=1; INSTALL=1 ;;
        *) echo "不明な引数: $arg" >&2; exit 2 ;;
    esac
done

# --reinstall: ビルドの前に、走っているアプリを**正しく**終わらせる。
# ⚠️ dist と /Applications の同名バンドルが併存すると、名前指定の quit は
# **片方にしか届かない**（二重起動の実例 2026-08-12 — MIDI とシリアルを
# 取り合う）。プロセスごとにバンドルパスへ向けて quit する
if [ "$REINSTALL" = "1" ]; then
    if pgrep -x Ladyland >/dev/null; then
        echo "==> 動いている Ladyland を終了（終了時保存を走らせる）"
        pgrep -x Ladyland | while read -r pid; do
            bundle=$(ps -p "$pid" -o command= | sed 's|/Contents/MacOS/Ladyland$||')
            if [ -n "$bundle" ]; then
                osascript -e "tell application \"$bundle\" to quit" 2>/dev/null || true
            fi
        done
        # 保存が要るので気長に待つ。ただし無限には待たない
        for _ in $(seq 1 40); do
            pgrep -x Ladyland >/dev/null || break
            sleep 0.5
        done
        if pgrep -x Ladyland >/dev/null; then
            echo "⚠️ 20 秒待っても終了しません。走っている .app を置き換えると壊れるので中止します。" >&2
            echo "   手で ⌘Q してから、もう一度実行してください。" >&2
            exit 1
        fi
        echo "    終了を確認"
    fi
fi

# バージョンは git から採る（タグが無ければコミット数 + 短縮ハッシュ）
cd "$REPO_ROOT"
SHORT_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")"
BUILD_VERSION="$(git rev-list --count HEAD).$(git rev-parse --short HEAD)"

echo "==> release ビルド"
cd "$PACKAGE_DIR"
swift build -c release --product Ladyland
BINARY="$(swift build -c release --product Ladyland --show-bin-path)/Ladyland"
test -x "$BINARY" || { echo "バイナリが見つかりません: $BINARY" >&2; exit 1; }

echo "==> fieldd を release ビルド（Field 常駐サーバ — アプリに同梱して
#    Ladyland が spawn / 版違いは自動入れ替え。design/07）"
cargo build --release --manifest-path "$REPO_ROOT/field/Cargo.toml"
FIELDD="$REPO_ROOT/field/target/release/fieldd"
test -x "$FIELDD" || { echo "fieldd が見つかりません: $FIELDD" >&2; exit 1; }

echo "==> バンドルを組む"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/Ladyland"
cp "$FIELDD" "$CONTENTS/Resources/fieldd"

echo "==> AppIcon を生成"
ICONSET="$(mktemp -d)/Ladyland.iconset"
swift "$REPO_ROOT/scripts/make-appicon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ladyland</string>
    <key>CFBundleDisplayName</key><string>Ladyland</string>
    <key>CFBundleIdentifier</key><string>club.chronista.ladyland</string>
    <key>CFBundleExecutable</key><string>Ladyland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- ライブ用途: ウィンドウを閉じたら終了（AppDelegate と対） -->
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# 署名: Developer ID があればそれを使い、無ければ ad-hoc に落ちる。
#
# Developer ID + Hardened Runtime にすると**公証に出せる** = 他の Mac へ
# 配れる（AirDrop / ダウンロードで付く quarantine を Gatekeeper が通す）。
# 自分の Mac でビルドして自分で使うだけなら ad-hoc で足りる。
#
# ⚠️ Hardened Runtime は既定で library validation を効かせ、**別 Team の
# dylib（= 第三者 AU プラグイン）の読み込みを拒否する**。ladyland は AU ホスト
# なので Ladyland.entitlements で明示的に外す（DAW が軒並みそうしているのと同じ）。
IDENTITY="${LADYLAND_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

if [ -n "$IDENTITY" ]; then
    echo "==> Developer ID で署名 + Hardened Runtime"
    echo "    $IDENTITY"
    # 同梱 fieldd（ネスト実行ファイル）も個別に署名 — 公証はこれが無いと弾く
    codesign --force --options runtime \
        --sign "$IDENTITY" "$CONTENTS/Resources/fieldd"
    codesign --force --options runtime \
        --entitlements "$REPO_ROOT/scripts/Ladyland.entitlements" \
        --sign "$IDENTITY" "$CONTENTS/MacOS/Ladyland"
    codesign --force --options runtime \
        --entitlements "$REPO_ROOT/scripts/Ladyland.entitlements" \
        --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> ad-hoc 署名（Developer ID が見つからないため）"
    codesign --force --deep --sign - "$APP" 2>/dev/null
fi

# Finder / Dock にアイコンを認識させる（キャッシュが古いままだと白いまま）
touch "$APP"

echo "==> できました: $APP"
echo "    version ${SHORT_VERSION} (${BUILD_VERSION})"

# --------------------------------------------------------------------------
# 配布物（公証 + staple + DMG）
# --------------------------------------------------------------------------
if [ "$MAKE_DIST" = "1" ]; then
    if [ -z "$IDENTITY" ]; then
        echo "配布には Developer ID 署名が必要です（ad-hoc では公証に出せません）" >&2
        exit 1
    fi

    # 資格情報が無いと notarytool は失敗する。**先に確認して手順を出す** —
    # 途中で落ちて「何をすればいいか分からない」状態を作らない
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat >&2 <<GUIDE

公証の資格情報 "$NOTARY_PROFILE" が未登録です。一度だけ以下を実行してください
（Apple ID とアプリ用パスワードの入力があるため、この scripts では代行しません）:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id <あなたの Apple ID> \\
      --team-id 3EQKG4B352 \\
      --password <アプリ用パスワード>

  ※ アプリ用パスワードは account.apple.com → サインインとセキュリティ →
     アプリ用パスワード で発行します（Apple ID 本体のパスワードではありません）

登録後にもう一度 scripts/build-app.sh --dist を実行してください。
GUIDE
        exit 1
    fi

    ZIP="$DIST/Ladyland-${SHORT_VERSION}.zip"
    echo "==> 公証へ提出（数分かかります）"
    # ditto は署名とシンボリックリンクを保つ。zip コマンドでは壊れる
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/    /'

    echo "==> staple（結果をアプリに貼る = 相手がオフラインでも検証が通る）"
    xcrun stapler staple "$APP" 2>&1 | sed 's/^/    /'
    rm -f "$ZIP"

    echo "==> DMG を作る"
    DMG="$DIST/Ladyland-${SHORT_VERSION}.dmg"
    STAGE="$(mktemp -d)/Ladyland"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    # 「Applications へドラッグ」の見慣れた作法にする
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Ladyland" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
        >/dev/null
    rm -rf "$(dirname "$STAGE")"

    # DMG 自体も署名 → 公証 → staple する。中の .app だけでは
    # `spctl -t install` が "no usable signature" で DMG を蹴る（実測 2026-09-12、v0.1.0）
    echo "==> DMG を署名して公証へ提出"
    codesign --sign "$IDENTITY" --timestamp "$DMG" 2>&1 | sed 's/^/    /'
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/    /'
    xcrun stapler staple "$DMG" 2>&1 | sed 's/^/    /'
    spctl -a -t install "$DMG" 2>&1 | sed 's/^/    /' || { echo "DMG の検証に失敗" >&2; exit 1; }

    echo "==> 配布物ができました"
    echo "    $DMG"
    echo "    受け取った人が /Applications に入れればそのまま開けます（警告なし）"
    echo
    echo "    ⚠️ 相手の Mac に AU プラグイン（KORG Gadget 等）が無いと"
    echo "       ラックは空のままです。楽器はこのアプリには同梱されません。"
fi

if [ "$INSTALL" = "1" ]; then
    echo "==> /Applications へ配置"
    rm -rf "/Applications/Ladyland.app"
    cp -R "$APP" "/Applications/Ladyland.app"
    touch "/Applications/Ladyland.app"
    echo "    /Applications/Ladyland.app"
fi

if [ "$RUN" = "1" ]; then
    echo "==> 起動"
    open "$APP"
fi

# --reinstall は **/Applications の方**を開く（dist ではなく、いま入れたもの）
if [ "$REINSTALL" = "1" ]; then
    echo "==> 起動（/Applications/Ladyland.app）"
    open -a Ladyland
fi
