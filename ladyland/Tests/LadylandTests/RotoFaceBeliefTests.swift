//! **面の信念**（mako 要望 2026-08-07「shadow の状態を表示できるくらいに
//! protocol に合わせないとだね」）。
//!
//! ⚠️ ここで固定するのは **「ズレが見えること」** であって「ズレないこと」ではない。
//! SMART 面はデバイスが到着を通知しないので**構造上ズレうる** — 直せないものを
//! 直ったことにせず、**推定だと名乗り続ける**のがこの型の仕事。

import Foundation
import Testing

@testable import Ladyland

@Suite("面の信念 — 推定と確認を混ぜない")
struct RotoFaceBeliefTests {

    // MARK: - 確からしさ

    @Test("デバイスの通知を受けたものは確認になる")
    func confirmedFromNotification() {
        let belief = FaceBelief.confirmed("PLUGIN", since: Date())
        #expect(belief.isConfirmed)
        #expect(belief.faceLabel == "PLUGIN")
        #expect(belief.summary().contains("確認"))
    }

    /// ⚠️ **推定は推定だと名乗る**。ここが「確認」に見えると、
    /// 実機とズレていても誰も気づけない（昨日それが起きた）
    @Test("送っただけのものは推定と名乗る")
    func assumedAnnouncesItself() {
        let belief = FaceBelief.assumed("SMART", since: Date())
        #expect(belief.isConfirmed == false)
        #expect(belief.summary().contains("推定"))
        #expect(belief.summary().contains("⚠️"), "目立つこと自体が要件")
    }

    /// **いつからその状態かが読めること** — 「42 秒ズレている」と
    /// 「たった今送った」では意味が違う
    @Test("いつからかが表示に出る")
    func summaryCarriesAge() {
        let past = Date().addingTimeInterval(-42)
        #expect(FaceBelief.assumed("SMART", since: past).summary().contains("42 秒"))

        let older = Date().addingTimeInterval(-300)
        #expect(FaceBelief.confirmed("MIX", since: older).summary().contains("5 分"))
    }

    @Test("未知は未知のまま")
    func unknownStaysUnknown() {
        #expect(FaceBelief.unknown.isConfirmed == false)
        #expect(FaceBelief.unknown.since == nil)
        #expect(FaceBelief.unknown.faceLabel == "不明")
    }

    // MARK: - 警報（昨日欠けていたもの）

    /// ⚠️ **これが本体**。推定 SMART の最中に `0B 01`（PLUGIN 到着）が来たら、
    /// 「ladyland は SMART だと思っていたが実機は PLUGIN だった」ということ。
    /// FUNC の引き戻しが無視されていたのに誰も気づかなかったのは、
    /// この警報が無かったため
    @Test("推定と実機が食い違ったら警報が出る")
    func contradictionIsReported() {
        let belief = FaceBelief.assumed("SMART", since: Date().addingTimeInterval(-8))
        let warning = FaceBelief.contradiction(belief, observed: "PLUGIN")
        let text = try! #require(warning)
        #expect(text.contains("SMART"), "何を推定していたか")
        #expect(text.contains("PLUGIN"), "実機はどこに居たか")
        #expect(text.contains("8 秒"), "どれだけズレていたか")
    }

    @Test("推定どおりなら黙っている")
    func agreementIsSilent() {
        let belief = FaceBelief.assumed("PLUGIN", since: Date())
        #expect(FaceBelief.contradiction(belief, observed: "PLUGIN") == nil)
    }

    /// ⚠️ **確認済みからの遷移は正常**（人が面を移しただけ）。
    /// ここで警報を出すと、面を移すたびに鳴って**本物の警報が埋もれる**
    @Test("確認済みからの面移動は警報にしない")
    func movingFromConfirmedIsNotAWarning() {
        let belief = FaceBelief.confirmed("MIX", since: Date())
        #expect(FaceBelief.contradiction(belief, observed: "PLUGIN") == nil)
    }

    @Test("未知からは警報にならない")
    func unknownNeverWarns() {
        #expect(FaceBelief.contradiction(.unknown, observed: "PLUGIN") == nil)
    }

    // MARK: - 遷移表

    /// ⚠️ **SMART へ行く経路には 1 つも通知が無い**。これがこの機種の
    /// 非対称性そのもので、崩れたら（= 通知が見つかったら）設計を見直せる
    @Test("SMART へ行く遷移はどれも通知を持たない")
    func smartHasNoNotification() {
        let toSmart = RotoFaceTransitions.all.filter { $0.target == "SMART" }
        #expect(!toSmart.isEmpty, "SMART へ行く経路は表にある")
        for transition in toSmart {
            #expect(transition.notification == nil, "\(transition.trigger) に通知がある？")
            #expect(transition.isConfirmable == false)
        }
    }

    /// PLUGIN と MIX は**確認できる** — 通知があるので推定に留まらない
    @Test("PLUGIN と MIX へ行く遷移は通知を持つ")
    func pluginAndMixAreConfirmable() {
        for target in ["PLUGIN", "MIX"] {
            let transitions = RotoFaceTransitions.all.filter { $0.target == target }
            #expect(!transitions.isEmpty)
            for transition in transitions {
                #expect(transition.isConfirmable, "\(transition.trigger) に通知が無い？")
            }
        }
    }

    /// ⚠️ **ホストの送信が面を動かす**行が表にあること。
    /// 「塗ると面が変わる」は直感に反するので、消えると次の人が
    /// `paintsTrackCells` の制限を「なぜ全部塗らないのか」と外してしまう
    @Test("ホストの送信が面を動かす経路が表にある")
    func hostSendsMoveTheFace() {
        let byHost = RotoFaceTransitions.all.filter { $0.origin == .host }
        #expect(byHost.contains { $0.trigger.contains("0A 11") }, "0A 11 の副作用が表にある")
        #expect(byHost.count >= 3, "selectFace 2 つ + 0A 11")
    }

    /// **由来が全行に付いていること** — 実測と推論を混ぜると、
    /// 「確かめた」と「そう思う」の区別が付かなくなる
    @Test("全ての遷移が由来を持ち、実測が過半")
    func everyTransitionHasProvenance() {
        #expect(!RotoFaceTransitions.all.isEmpty)
        for transition in RotoFaceTransitions.all {
            #expect(!transition.provenance.label.isEmpty)
        }
        #expect(
            RotoFaceTransitions.measuredCount * 2 > RotoFaceTransitions.all.count,
            "実測が過半（推論だけの表なら設計の根拠にならない）")
    }

    /// **効かないと分かったものも表に残す** — 次の人が同じ道を通らないように
    @Test("効かないと分かった操作も表に残っている")
    func deadEndsAreKept() {
        #expect(RotoFaceTransitions.all.contains { $0.trigger.contains("MODE") })
        #expect(RotoFaceTransitions.all.contains { $0.target.contains("無視") })
    }
}
