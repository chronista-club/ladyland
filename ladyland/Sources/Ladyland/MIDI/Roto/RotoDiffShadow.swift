//! 差分焼きの影 — 「実機に焼いてある姿」の帳簿（2026-08-12 起工）。
//!
//! INST 冊のライブラベル（席名 = 選択スロットの割当名）とトラックカラーは
//! 選択のたびに変わるが、**全 96 席の焼き直しは数秒 CC が止まる**。
//! そこで焼いたリクエストのバイト列を席ごとに覚えておき、次に期待する姿との
//! **差分だけ**をシリアルへ撃つ（mako 裁定 2026-08-12「選択変更で自動差分焼き」）。
//!
//! バイト列そのものを比較キーにする — 名前・色・CC どこが変わっても
//! 「実機に書かれるものが変わったか」だけを見る（第 2 の同値定義を作らない）。
//!
//! ## 影の信頼が崩れたら全部捨てる
//!
//! シリアル書き込みが途中で失敗したら、どこまで実機に入ったか分からない。
//! 中途半端に信じるより `invalidate()` で影ごと捨て、次の全焼きまで差分焼きを
//! 黙らせる（全焼き = `prime` が信頼の再出発点）。
//!
//! ## 影はディスクに残す（Codable）
//!
//! メモリ上だけだと**アプリを再起動するたびに全焼きが要る**（mako 報告
//! 2026-08-12「Track の変更に MainLCD の #n が追随しない」の正体 — 再起動で
//! 影が消えて差分焼きが黙っていた）。実機の設定はフラッシュに残るのだから、
//! 影も残すのが対称。アプリ外で実機を変えたら（ROTO-SETUP 等）狂うが、
//! その時は全焼きが再出発点 — 従来と同じ安全弁

import Foundation

/// 純粋ロジック（テスト対象）。スレッド安全ではない — 呼び手（AppState）が
/// MainActor で使う
struct RotoDiffShadow: Codable {
    private var shadow: [RotoMidiSetupExport.SeatKey: [UInt8]]?

    /// 影があるか（= 全焼きに成功して以降、失敗していない）。
    /// false の間、差分焼きは沈黙する
    var isPrimed: Bool { shadow != nil }

    /// 全焼きに成功した — 焼いたリクエストをそのまま影にする
    mutating func prime(_ requests: [(key: RotoMidiSetupExport.SeatKey, request: [UInt8])]) {
        shadow = Dictionary(uniqueKeysWithValues: requests.map { ($0.key, $0.request) })
    }

    /// 影を捨てる（書き込み失敗・切断 — 実機の姿が信用できなくなった）
    mutating func invalidate() {
        shadow = nil
    }

    /// 期待する全席から、影と違う分だけ返す。**返した分は焼けたとみなして
    /// 影を先に進める** — 失敗したら呼び手が `invalidate()` すること
    mutating func pending(
        _ requests: [(key: RotoMidiSetupExport.SeatKey, request: [UInt8])]
    ) -> [[UInt8]] {
        guard shadow != nil else { return [] }
        var sends: [[UInt8]] = []
        for (key, request) in requests where shadow?[key] != request {
            shadow?[key] = request
            sends.append(request)
        }
        return sends
    }
}
