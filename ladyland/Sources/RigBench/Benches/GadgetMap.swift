//! Korg Gadget の全インストゥルメントを解剖して、割当マッピングの正本を作る
//! （mako 要望 2026-08-04「一度正確にマッピングする作業をしてから進めよう」）。
//!
//! **なぜ要るか**: ラックの割当に漏れがあるか調べたとき、address の連続性からは
//! 判定できなかった。Gadget は **先頭 3 つ（Pitch Bend / Modulation Wheel /
//! Damper）をホイール類に充てる**規約があり、それを知らずに「0,1,2 が抜けている」
//! と誤検知した。さらに **AU が公開しないパラメータがある**（Firenze の PICKUP は
//! GUI にあるが AU に無い）。憶測を止めるには、実機から取った一覧を持つしかない。
//!
//!   swift run RigBench gadget-map          # 一覧（名前・パラメータ数）
//!   swift run RigBench gadget-map --json   # JSON（割当との突き合わせ用）
//!   swift run RigBench gadget-map Pompei   # 1 機種の詳細

import AVFoundation
import Foundation

struct GadgetMap: Bench {
    let name = "gadget-map"
    let summary = "Korg Gadget 全機種のパラメータを解剖してマッピングの正本を作る"

    /// Gadget が先頭に置くホイール類（ノブに載せる必要が無い枠）
    static let wheelParameters = ["Pitch Bend", "Modulation Wheel", "Damper"]

    func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        let wantsJSON = arguments.contains("--json")
        let query = arguments.first { !$0.hasPrefix("--") }

        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        let all = AVAudioUnitComponentManager.shared().components(matching: description)
        let gadgets = all
            .filter { $0.manufacturerName.localizedCaseInsensitiveContains("KORG") }
            .filter { query == nil || $0.name.localizedCaseInsensitiveContains(query!) }
            .sorted { $0.name < $1.name }

        guard !gadgets.isEmpty else { throw BenchError("Korg の楽器 AU が見つからない") }
        if !wantsJSON {
            print("Korg Gadget \(gadgets.count) 機種を解剖します（AU を順にロード）\n")
        }

        var report: [[String: Any]] = []
        for component in gadgets {
            guard let parameters = try? loadParameters(component) else {
                if !wantsJSON { print("  ⚠️ \(component.name): ロードに失敗") }
                continue
            }
            let wheels = parameters.filter { Self.wheelParameters.contains($0.name) }
            let knobs = parameters.filter { !Self.wheelParameters.contains($0.name) }
            let stepped = parameters.filter { $0.steps > 0 }

            report.append([
                "name": component.name,
                "total": parameters.count,
                "wheels": wheels.count,
                "assignable": knobs.count,
                "stepped": stepped.count,
                "parameters": parameters.map {
                    ["address": $0.address, "name": $0.name, "steps": $0.steps]
                },
            ])

            if wantsJSON { continue }
            print(
                "\(component.name)"
                    + "  全\(parameters.count)"
                    + "  ホイール\(wheels.count)"
                    + "  **割当対象\(knobs.count)**"
                    + (stepped.isEmpty ? "" : "  段階つまみ\(stepped.count)"))
            if query != nil {
                for p in parameters {
                    let kind = p.steps > 0 ? "[段階 \(p.steps)]" : "[連続]"
                    let wheel = Self.wheelParameters.contains(p.name) ? "  ← ホイール枠" : ""
                    print("    addr=\(p.address)  \(kind) \(p.name)\(wheel)")
                }
            }
        }

        if wantsJSON,
            let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("\n※ **割当対象** が ladyland のノブに載せるべき数。")
            print("  ホイール枠（Pitch Bend / Modulation Wheel / Damper）は")
            print("  物理コントローラが担当するので、マトリクスに並べる必要は無い。")
            print("⚠️ **AU が公開しないパラメータは、ここにも出てこない**")
            print("  （Firenze の PICKUP は GUI にあるが AU に無い = ホストから触れない）")
        }
    }

    private struct Parameter {
        let address: UInt64
        let name: String
        /// 段階つまみのステップ数（0 = 連続）
        let steps: Int
    }

    /// AU をロードしてパラメータツリーを読む（同期待ち）
    private func loadParameters(_ component: AVAudioUnitComponent) throws -> [Parameter] {
        let semaphore = DispatchSemaphore(value: 0)
        var loaded: AVAudioUnit?
        AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) {
            unit, _ in
            loaded = unit
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success, let unit = loaded else {
            throw BenchError("インスタンス化に失敗")
        }
        defer { _ = unit }

        guard let tree = unit.auAudioUnit.parameterTree else { return [] }
        return tree.allParameters.map { parameter in
            Parameter(
                address: parameter.address,
                name: parameter.displayName,
                steps: parameter.valueStrings?.count ?? 0)
        }
    }
}
