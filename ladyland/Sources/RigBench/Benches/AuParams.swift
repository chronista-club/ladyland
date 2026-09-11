//! AU のパラメータツリーを解剖する（2026-08-03 起工）。
//!
//! **なぜ要るか**: ROTO への投影は「連続つまみ」だけでは足りない。プラグインには
//! **段階つまみ**（エフェクト種別のような列挙）が混ざっており、ROTO はそれを
//! ステップ数 + 各段の名前で受け取れる（haptic のクリック感付き）。
//! どのパラメータがどちらなのかは AU に聞くしかないので、その耳を用意する。
//!
//! 使い方:
//!   swift run RigBench au-params                 # 楽器 AU の一覧
//!   swift run RigBench au-params Fairbanks       # 名前で部分一致 → 全パラメータ
//!   swift run RigBench au-params Fairbanks Mod   # さらにパラメータ名で絞る
//!
//! 出力の見方:
//!   [段階 N] = valueStrings があり離散（ROTO の steps + stepNames に載る）
//!   [連続]   = 通常のポット。ROTO では 0-16383 の 14bit で投影する

import AVFoundation
import Foundation

struct AuParams: Bench {
    let name = "au-params"
    let summary = "AU のパラメータツリーを解剖（段階つまみ / 連続つまみの判別）"

    func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        let components = AVAudioUnitComponentManager.shared().components(matching: description)

        guard let query = arguments.first else {
            print("楽器 AU（\(components.count) 個）— 名前の一部を渡すと解剖します\n")
            for component in components.sorted(by: { $0.name < $1.name }) {
                print("  \(component.name)  [\(component.manufacturerName)]")
            }
            return
        }

        let matches = components.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        guard let component = matches.first else {
            throw BenchError("'\(query)' に一致する楽器 AU が無い")
        }
        if matches.count > 1 {
            print("※ \(matches.count) 件一致 — 先頭を使う: \(component.name)\n")
        }

        let filter = arguments.dropFirst().first
        print("=== \(component.name) [\(component.manufacturerName)] ===\n")

        // AU の実体化は非同期。**プラグイン画面を出さずに**ツリーだけ取る
        let semaphore = DispatchSemaphore(value: 0)
        var instantiated: AVAudioUnit?
        var failure: Error?
        AVAudioUnit.instantiate(with: component.audioComponentDescription) { unit, error in
            instantiated = unit
            failure = error
            semaphore.signal()
        }
        // Gadget 系は認証ダイアログで止まりうるので待ち時間に上限を置く
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw BenchError("実体化がタイムアウト（認証ダイアログが出ていない？）")
        }
        if let failure { throw BenchError("実体化に失敗: \(failure)") }
        guard let tree = instantiated?.auAudioUnit.parameterTree else {
            throw BenchError("parameterTree を持たない AU")
        }

        var total = 0
        var stepped = 0
        for parameter in tree.allParameters {
            if let filter, !parameter.displayName.localizedCaseInsensitiveContains(filter) {
                continue
            }
            total += 1
            let strings = parameter.valueStrings ?? []
            let kind: String
            if !strings.isEmpty {
                stepped += 1
                kind = "[段階 \(strings.count)]"
            } else {
                kind = "[連続]"
            }
            print(
                "\(kind) \(parameter.displayName)"
                    + "  addr=\(parameter.address)"
                    + "  範囲=\(fmt(parameter.minValue))…\(fmt(parameter.maxValue))"
                    + "  現在=\(fmt(parameter.value))"
                    + (parameter.unitName.map { "  単位=\($0)" } ?? ""))
            if !strings.isEmpty {
                // ROTO の stepNames に載るのは 16 段まで（それ以上は名前無しの段階）
                let shown = strings.prefix(24)
                for (index, label) in shown.enumerated() {
                    print("        \(index): \(label)")
                }
                if strings.count > shown.count {
                    print("        …他 \(strings.count - shown.count) 段")
                }
            }
        }
        print("\n--- \(total) パラメータ（うち段階つまみ \(stepped)）---")
    }

    private func fmt(_ value: AUValue) -> String {
        String(format: "%g", value)
    }
}
