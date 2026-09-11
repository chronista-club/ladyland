//! 影の可視化（mako 要望 2026-08-06「ROTO の状態と一致してる shadow データを
//! 表示したい」）。
//!
//! ⚠️ **これは診断器**なので、表示が嘘をつくと切り分けそのものが壊れる。
//! 影 → 表示値の変換を純関数で固定する。
//!
//! ⚠️ **読むだけ**であることも固定する — 影は差分抑止の根拠なので、
//! 表示のために触ると送信が壊れる。

import Testing

@testable import Ladyland

@Suite("ROTO の影の可視化")
struct RotoInspectionTests {

    // MARK: - `"色|ラベル"` の分解

    @Test("色とラベルに分かれる")
    func parsesColorAndLabel() {
        let (color, label) = RotoInspection.parseEntry("22|Cutoff")
        #expect(color == 22)
        #expect(label == "Cutoff")
    }

    /// ⚠️ **ラベル側に `|` が入りうる**ので、最初の 1 個でだけ切る
    @Test("ラベルに `|` が入っていても壊れない")
    func parsesLabelContainingPipe() {
        let (color, label) = RotoInspection.parseEntry("7|A|B")
        #expect(color == 7)
        #expect(label == "A|B", "2 個目以降は切らない")
    }

    /// **表示は落とさない** — 分解できなくても全部ラベルとして出す
    @Test("分解できない形でも表示は落とさない")
    func fallsBackToWholeString() {
        let (color, label) = RotoInspection.parseEntry("こわれた")
        #expect(color == nil)
        #expect(label == "こわれた")

        let (badColor, badLabel) = RotoInspection.parseEntry("xx|Cutoff")
        #expect(badColor == nil, "色として読めない")
        #expect(badLabel == "xx|Cutoff", "丸ごと出す")
    }

    @Test("影に無ければ両方 nil")
    func absentEntryIsNil() {
        let (color, label) = RotoInspection.parseEntry(nil)
        #expect(color == nil)
        #expect(label == nil)
    }

    /// 空ラベルも「送った」なので `nil`（未送信）とは違う
    @Test("空ラベルは未送信と区別される")
    func emptyLabelIsNotAbsent() {
        let (color, label) = RotoInspection.parseEntry("70|")
        #expect(color == 70)
        #expect(label == "", "空文字であって nil ではない")
    }

    // MARK: - モーター位置

    /// ⚠️ **`apply` と同じ割り算**にする。ここがずれると
    /// 「画面では合っているのに音が違う」を作る（`apply` は `raw / 16383`）
    @Test("14bit raw を 0...1 へ — apply と同じ割り算")
    func normalizesLikeApply() {
        #expect(RotoInspection.normalize(0) == 0)
        #expect(RotoInspection.normalize(16383) == 1)
        #expect(abs(RotoInspection.normalize(8192) - 0.5) < 0.001)
    }

    @Test("範囲外は丸める")
    func clampsOutOfRange() {
        #expect(RotoInspection.normalize(-1) == 0)
        #expect(RotoInspection.normalize(99999) == 1)
    }

    // MARK: - 影 → 8 セル

    @Test("影から現在ページの 8 セルを起こす")
    func buildsCellsFromShadow() {
        var shadow = RotoShadow()
        shadow.label[16] = "22|Cutoff"
        shadow.motorRaw[16] = 8192

        let cells = RotoInspection.cells(shadow: shadow, knobs: 8) { knob in
            16 + knob  // ページ内位置 → マトリクス座標
        }

        #expect(cells.count == 8)
        #expect(cells[0].knob == 1, "画面の並びは 1 始まり")
        #expect(cells[0].cell == 16, "マトリクス座標 = CC 番号")
        #expect(cells[0].label == "Cutoff")
        #expect(cells[0].color == 22)
        #expect(cells[0].motorRaw == 8192)
        #expect(abs((cells[0].motorNormalized ?? 0) - 0.5) < 0.001)

        // まだ送っていない席は nil（「‐」で出る）
        #expect(cells[1].label == nil)
        #expect(cells[1].motorRaw == nil)
        #expect(cells[1].motorNormalized == nil)
    }

    /// ページ端で席が無いノブは `cell = -1`（画面が「席が無い」と言える）
    @Test("席が無いノブは cell = -1")
    func missingSeatIsMarked() {
        let cells = RotoInspection.cells(shadow: RotoShadow(), knobs: 8) { knob in
            knob < 4 ? 16 + knob : nil  // 後半は席が無いページ
        }
        #expect(cells[0].cell == 16)
        #expect(cells[7].cell == -1)
        #expect(cells[7].label == nil)
    }

    /// ⚠️ **読むだけ**。影は差分抑止の根拠なので、覗いても中身が変わらないこと
    @Test("影を読んでも中身が変わらない")
    func readingDoesNotMutateShadow() {
        var shadow = RotoShadow()
        shadow.label[16] = "22|Cutoff"
        shadow.motorRaw[16] = 100
        let before = shadow

        _ = RotoInspection.cells(shadow: shadow, knobs: 8) { 16 + $0 }

        #expect(shadow.label == before.label)
        #expect(shadow.motorRaw == before.motorRaw)
    }

    // MARK: - K1-K8 ごとの確からしさ（mako 要望 2026-08-07）

    /// ⚠️ **`motorRaw` は送信でも受信でも進む**ので、これが無いと
    /// 「実機がそこに居る」と「そこへ送っただけ」が混ざる
    @Test("受信で裏が取れた K だけ確認になる")
    func onlyReceivedMotorIsConfirmed() {
        var shadow = RotoShadow()
        shadow.motorRaw[16] = 8192
        shadow.motorObserved.insert(16)  // 受信で観測
        shadow.motorRaw[17] = 4096  // 送っただけ

        let cells = RotoInspection.cells(shadow: shadow, knobs: 8) { 16 + $0 }
        #expect(cells[0].motorConfirmed, "受信したものは確認")
        #expect(cells[1].motorConfirmed == false, "送っただけは推定のまま")
    }

    /// ⚠️ **送ったら推定へ戻る** — 送信は「実機がそうなった」証拠にならない
    @Test("送り直すと確認から推定へ戻る")
    func sendingDemotesToAssumed() {
        var shadow = RotoShadow()
        shadow.motorRaw[16] = 8192
        shadow.motorObserved.insert(16)

        _ = shadow.motorChanged(16, 0.9, force: false)

        #expect(shadow.motorObserved.contains(16) == false)
    }

    /// 未割当の K は `LADYLAND_PARK_EMPTY_KNOBS` で値を送っていない =
    /// **触っても動かないのが正常**。それが読めること
    @Test("割当の有無が K ごとに出る")
    func assignmentIsVisiblePerKnob() {
        let cells = RotoInspection.cells(
            shadow: RotoShadow(), knobs: 8, cellForKnob: { 16 + $0 },
            isAssigned: { $0 == 16 })
        #expect(cells[0].assigned)
        #expect(cells[1].assigned == false)
    }

    /// 席が無い K は割当も確認も持たない
    @Test("席が無い K は割当なし・未確認")
    func seatlessKnobIsBlank() {
        let cells = RotoInspection.cells(
            shadow: RotoShadow(), knobs: 8, cellForKnob: { _ in nil },
            isAssigned: { _ in true })
        #expect(cells[0].assigned == false)
        #expect(cells[0].motorConfirmed == false)
    }

    @Test("初期値は未接続・空")
    func emptyIsUnconnected() {
        #expect(RotoInspection.empty.connected == false)
        #expect(RotoInspection.empty.cells.isEmpty)
        #expect(RotoInspection.empty.shadowEmpty)
    }
}
