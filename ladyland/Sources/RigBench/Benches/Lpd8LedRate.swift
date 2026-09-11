//! LPD8 mk2 LED SysEx レート上限ベンチ（RigBench 第 1 号、2026-07-31 初測）。
//!
//! 0x06 (LED color update) フレームを段階的なレートで送り続け、
//!   - 実機の見た目（虹パターンが 滑らか / カクつく / 固まる）
//!   - ドライバ側のバックプレッシャ（完了コールバックの滞留・遅延）
//! の両方を観測する。1 フレーム = 56 bytes・8 パッド一括（部分更新はプロトコルに無い）。
//!
//! 仕様出典: 逆解析 github.com/john-kuan/lpd8mk2sysex（E1/doc 22 で実機確定済み）
//! M5 初測の結果: サービス約 107ms/frame ≈ 9-10fps が上限（Creo mem_1CdZe314eTYVofGrhZN6xy）
//! 終了時は全消灯フレームを送る。元のプログラム色に戻すには本体を挿し直す。

import CoreMIDI
import Foundation
import Lpd8Kit

struct Lpd8LedRate: Bench {
    let name = "lpd8-led-rate"
    let summary = "LPD8 mk2 LED SysEx のレート上限（0x06 全パッド一括、5→120Hz ランプ）"

    private let steps: [Double] = [5, 10, 15, 20, 30, 45, 60, 90, 120]
    private let stepDuration = 5.0

    func run() throws {
        _ = try MIDIOut.makeClient("rigbench")
        let dest = try MIDIOut.destination(matching: "LPD8")
        let stats = Stats()

        print("""
        LPD8 mk2 LED レート上限テスト — \(steps.map { "\(Int($0))" }.joined(separator: "/")) Hz を各 \(Int(stepDuration))s
        各ステップ冒頭に全パッドが白く一瞬光る（区切りマーカー）。
        実機を見て: 虹の流れが 滑らか / カクつく / 固まる、を段ごとにメモしてください。
        """)

        var report: [String] = []

        for (idx, hz) in steps.enumerated() {
            print("STEP \(idx + 1)/\(steps.count): \(Int(hz)) Hz")
            report.append(runStep(hz: hz, dest: dest, stats: stats))
            Thread.sleep(forTimeInterval: 0.6) // 目視の区切り
        }

        // 終了: 全消灯
        MIDIOut.sendSysex(ledFrame(Array(repeating: (0, 0, 0), count: 8)), to: dest, stats: stats)
        Thread.sleep(forTimeInterval: 0.3)

        print("\n===== サマリー =====")
        report.forEach { print($0) }
        print("""

        読み方:
          最大滞留 ≤ 2 かつ 完了遅延 max が数 ms 台 → そのレートはドライバ的に余裕
          滞留が増える / 排水に時間がかかる → ワイヤ・ドライバ側の飽和
          指標が綺麗なのに目視でカクつく → LPD8 ファームウェア側の処理落ち（こちらが真の上限）
        """)
    }

    private func runStep(hz: Double, dest: MIDIEndpointRef, stats: Stats) -> String {
        // 区切りマーカー: 白 → 消灯
        MIDIOut.sendSysex(ledFrame(Array(repeating: (127, 127, 127), count: 8)), to: dest, stats: stats)
        Thread.sleep(forTimeInterval: 0.15)
        MIDIOut.sendSysex(ledFrame(Array(repeating: (0, 0, 0), count: 8)), to: dest, stats: stats)
        Thread.sleep(forTimeInterval: 0.15)
        _ = stats.snapshotAndReset() // マーカー分は捨てる

        let intervalNs = UInt64(1_000_000_000 / hz)
        let frameCount = Int(stepDuration * hz)
        let startNs = DispatchTime.now().uptimeNanoseconds
        var lateFrames = 0
        var abortedAt: Int? = nil

        for frame in 0..<frameCount {
            let targetNs = startNs + intervalNs * UInt64(frame)
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs < targetNs {
                Thread.sleep(forTimeInterval: Double(targetNs - nowNs) / 1_000_000_000)
            } else if nowNs - targetNs > intervalNs {
                lateFrames += 1
            }

            // 虹パターン: 4 秒で 1 周（レート非依存 — fps が高いほど滑らかに見えるはず）
            let elapsed = Double(frame) / hz
            let colors = (0..<8).map { pad in
                hsvToRGB(h: elapsed * 0.25 + Double(pad) / 8.0, s: 1.0, v: 1.0)
            }
            let outstanding = MIDIOut.sendSysex(ledFrame(colors), to: dest, stats: stats)

            // 滞留が積み上がる = ドライバ/デバイスが食い切れていない。無制限に流し込まない
            if outstanding > 100 {
                abortedAt = frame
                break
            }
        }

        // 完了コールバックの排水を待つ（排水時間そのものも指標）
        let drainStartNs = DispatchTime.now().uptimeNanoseconds
        while stats.outstandingNow > 0,
              DispatchTime.now().uptimeNanoseconds - drainStartNs < 2_000_000_000 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let drainMs = Double(DispatchTime.now().uptimeNanoseconds - drainStartNs) / 1_000_000

        let snap = stats.snapshotAndReset()
        let line = String(
            format: "%3d Hz: 送信 %3d / 完了 %3d, 最大滞留 %2d, 完了遅延 avg %5.2fms / max %6.2fms, 送信遅れ %d, 排水 %.0fms%@",
            Int(hz), snap.sent, snap.completed, snap.maxOutstanding, snap.avgMs, snap.maxMs,
            lateFrames, drainMs,
            abortedAt.map { " ⚠️ 滞留>100 で frame \($0) 中断" } ?? ""
        )
        print("  → " + line)
        return line
    }
}

// MARK: - SysEx エンコード

/// フレーム構築は Lpd8Kit.Lpd8SysEx に委譲。ベンチのパターンは 0-127 なので
/// pack7 では hi = 0 となり、抽出前とワイヤバイトが同一（比較条件保存）
private func ledFrame(_ colors: [(r: Int, g: Int, b: Int)]) -> [UInt8] {
    Lpd8SysEx.ledFrame(colors.map { c in
        Rgb8(
            UInt8(max(0, min(127, c.r))),
            UInt8(max(0, min(127, c.g))),
            UInt8(max(0, min(127, c.b)))
        )
    })
}

private func hsvToRGB(h: Double, s: Double, v: Double) -> (r: Int, g: Int, b: Int) {
    let h6 = (h - floor(h)) * 6.0
    let i = Int(h6) % 6
    let f = h6 - floor(h6)
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let rgb: (Double, Double, Double)
    switch i {
    case 0: rgb = (v, t, p)
    case 1: rgb = (q, v, p)
    case 2: rgb = (p, v, t)
    case 3: rgb = (p, q, v)
    case 4: rgb = (t, p, v)
    default: rgb = (v, p, q)
    }
    return (Int(rgb.0 * 127), Int(rgb.1 * 127), Int(rgb.2 * 127))
}
