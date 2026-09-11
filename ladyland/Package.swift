// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ladyland",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // creo-ui デザインシステム（Creo エコシステム共通の視覚言語）。
        // GitHub URL 参照はルートに Package.swift が無いため未対応 — 艦隊の
        // 「path 依存で共有」パターン（cortex ↔ midistage-profiles と同型）
        .package(path: "../../creo-ui/packages/swift"),
        // Unison Protocol クライアント（Field 接続 — design/07。QUIC + protobuf、
        // server は fieldd (Rust)。creo-ui と同じ艦隊 path 依存パターン）
        .package(path: "../../club-unison"),
        // 永続化の SSOT（mako 裁定 2026-08-02「GRDB 導入しよう。ここが SSOT」）。
        // SQLite ツールキット — 接続を直接触らせない設計（DatabaseQueue が
        // 書き込みを直列化）なので、競合を「解決」せず存在させない構造に載る
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        // LPD8 mk2 SysEx の純粋層 + CoreMIDI 送信（design/06 §8）。
        // 本体 Ladyland と RigBench の両方から使う共有ライブラリ
        .target(
            name: "Lpd8Kit",
            path: "Sources/Lpd8Kit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // ROTO-CONTROL SysEx の純粋層（docs/roto-control/protocol.md）。
        // 本体の RotoService と RigBench の roto-probe が共有する
        .target(
            name: "RotoKit",
            path: "Sources/RotoKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Keystage SysEx の純粋層（docs/keystage/README.md）。
        // Scene / Global の Dump 経由でしか Arp・Chord 設定に触れないため、
        // 7bit ⇄ 8bit の詰め替えとオフセット定義をここに閉じ込める
        .target(
            name: "KeystageKit",
            path: "Sources/KeystageKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Ladyland",
            dependencies: [
                "Lpd8Kit",
                "RotoKit",
                "KeystageKit",
                .product(name: "CreoUI", package: "swift"),
                .product(name: "UnisonClient", package: "club-unison"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Ladyland",
            swiftSettings: [
                // Swift Testing の swift test 統合には tools 6.0 が必要。
                // 言語モードは v5 に留め、strict concurrency への移行は別途判断する
                .swiftLanguageMode(.v5)
            ]
        ),
        // 機材測定ベンチ集（本体とは独立、8/8 本番には不使用）。
        // cortex の rigcheck の Swift 側相棒 — swift run RigBench で一覧
        .executableTarget(
            name: "RigBench",
            dependencies: ["Lpd8Kit", "RotoKit", "KeystageKit"],
            path: "Sources/RigBench",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LadylandTests",
            dependencies: ["Ladyland", "Lpd8Kit", "KeystageKit"],
            path: "Tests/LadylandTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
