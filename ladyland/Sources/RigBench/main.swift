//! RigBench — 機材測定ベンチの束ね（cortex の `cargo run --bin rigcheck` の Swift 側相棒）。
//!
//! cargo bench / criterion は「統計反復のマイクロベンチ」だが、機材測定は
//! 副作用あり（LED が光る、実機状態が変わる）・1 ショット・目視併用のシステム測定。
//! Rust でも criterion に載せず --bin にする類の仕事なので、ここも自作 harness。
//!
//! 使い方:
//!   swift run RigBench            # ベンチ一覧
//!   swift run RigBench <name>     # 実行

import Foundation

let benches: [Bench] = [
    Lpd8LedRate(),
    Lpd8ProgramDump(),
    MidiSniff(),
    KeystageOled(),
    KeystageScene(),
    GadgetMap(),
    RotoProbe(),
    RotoMidiProbe(),
    RotoPluginProbe(),
    RotoAdminProbe(),
    AuParams(),
    FftBackendBench(),
]

let args = Array(CommandLine.arguments.dropFirst())

guard let name = args.first else {
    print("RigBench — 機材測定ベンチ集")
    print("使い方: swift run RigBench <name>\n")
    for bench in benches {
        print("  \(bench.name)  —  \(bench.summary)")
    }
    exit(0)
}

guard let bench = benches.first(where: { $0.name == name }) else {
    print("'\(name)' というベンチは無い。あるもの: \(benches.map(\.name).joined(separator: ", "))")
    exit(1)
}

do {
    try bench.run()
} catch {
    print("失敗: \(error)")
    exit(1)
}
