//! ROTO MIDI モードの冊構成（2026-08-11 起工、08-12 にミキサー冊 + 直接焼き）。
//!
//! ROTO の本線は MIDI モード。**1 setup = 4 ページ × 8 ノブ = 32 席**で、
//! ← → 矢印がページ送り。冊の配置（mako 裁定 2026-08-12「MIXER は SETUP 01 で」）:
//!
//!   SETUP 01 "LL MIXER"  = スロット 1-32 の gain（CC = スロット番号、**ch2**）
//!   SETUP 02 "LL P1-P4"  = 64 席正典の前半（CC0-31、ch1）
//!   SETUP 03 "LL P5-P8"  = 後半（CC32-63、ch1）
//!
//! **チャンネル = 意味論の名前空間**: ch1 = 選択スロットの席（KnobPages 正典、
//! Keystage と同じ CC 地図）、ch2 = ミキサー（受信は RotoService.handleShort の
//! 早期 return、送信は mixerSync レーン。CC 0-63 = ノブ gain / 64+ = ボタン =
//! **Track の直接選択**）。ch3 のコマンドレーン（RK 冊切替）は 2026-08-13 に
//! オミット — 冊の移動は実機の SEL で。
//!
//! 実機への入れ方は 2 経路（同じビルダから生成 — 第 2 の定義を作らない）:
//! 1. **直接焼き（本線）**: アドミンポートへ直接書く。ROTO-SETUP 不要・
//!    差し直し不要・ライブ反映。⚠️ 焼いている数秒は実機の CC が止まる
//! 2. **Export All 互換 JSON**: ROTO-SETUP の File > Import 用（控え）
//!
//! ミキサー冊の席名は**焼いた時点のスロット名のスナップショット**。
//! 楽器を入れ替えたら焼き直せば追従する（ライブラベルの先取り）

import Foundation
import RotoKit

enum RotoMidiSetupExport {
    /// 1 冊あたりのページ数（4 ページ × 8 ノブ = 32 席/冊）
    static let pagesPerSetup = 4

    /// 席レーン（選択スロットのパラメータ）/ ミキサーレーンの送信チャンネル —
    /// チャンネル = 意味論の名前空間。
    /// ch3 のコマンドレーン（RK 冊切替）は 2026-08-13 に mako 裁定でオミット —
    /// 「テストで Page を辿れるかの残骸」。冊の移動は実機の SEL で
    static let seatChannel = 1
    static let mixerChannel = 2

    /// ch2 のボタン CC = この値 + スロット番号。ch2 の CC 空間は半分で割る —
    /// 下半分 0-63 はノブ（gain）、上半分 64+ はボタン（Track の直接選択）
    static let mixerButtonCCBase = 64

    /// ミキサー冊 1 冊が載せるスロット数（4 ページ × 8 = バンク 1-4）
    static let mixerSlotCount = pagesPerSetup * KnobPages.perPage

    /// ミキサーの総スロット数 = 2 冊分（Ladyland の Track 64 に対応。
    /// CC 空間は ch2 に自然に収まる — ノブ = CC 0-63 / ボタン = CC 64-127）
    static let mixerTotalSlots = mixerSlotCount * 2

    /// **冊の物理配置**（SETUP index、0 始まり。mako 裁定 2026-08-14
    /// 「やっぱり -MIXER, +MIXER 表記から MIXER-, MIXER+ に。-Tn は TRn-/+ に」
    /// — 前置の記号は後置へ、ペア記号 - / + は維持）:
    ///   SETUP 01 = MIXER-（T1-32） / SETUP 02 = MIXER+（T33-64） /
    ///   SETUP 03 = INST-（P1-P4） / SETUP 04 = INST+（P5-P8）
    static let mixerSetup1 = 0
    static let mixerSetup2 = 1
    static let instSetup1 = 2
    static let instSetup2 = 3

    /// INST 冊名のフォールバック（選択トラックが無いとき）
    static let instFallbackNames = ["INST-", "INST+"]
    static var bookCount: Int { 4 }

    /// **丸ごと掃除する冊**。SETUP 05/06 = 旧配置の残骸（旧 05 = MIXER。
    /// 06 は旧 MIXER 2 計画の予定地 — 未焼きだが念のため掃く）。
    /// 冊名を工場既定の「SETUP nn」へ戻し、全 64 席を clear する。
    /// 新しい実験冊が残骸になったらここへ番号を足す
    static let scrubSetups = [4, 5]

    /// INST 冊名 = 「**TR{トラック番号}{-|+} {inst 名}**」（mako 裁定 2026-08-14
    /// 「-Tn は TRn-/+ に」— 記号は後置、- = P1-P4 / + = P5-P8。
    /// MIXER- / MIXER+ と同じ文法で SEL 画面の 4 冊が読める）。
    /// 例: 「TR2- Montreal」「TR2+ Montreal」。冊名は差分焼きに乗る = 選択に自動追従。
    ///
    /// ⚠️ **setup 名の実効は 12 バイト**（13 バイト枠 − NULL 終端。実機実測
    /// 2026-08-13。knob 名は 13 字ちょうどでも通るのと**非対称**）。
    /// 収まらないときは inst 名を切る
    static func instBookName(
        set: Int, selectedTrack: Int?, trackName: String? = nil
    ) -> String {
        guard let track = selectedTrack else { return instFallbackNames[set - 1] }
        let mark = set == 1 ? "-" : "+"
        // inst 名が無いときは番号へ畳む（「TR2-」/「TR2+」）
        guard let name = trackName, !name.isEmpty else { return "TR\(track)\(mark)" }
        let head = "TR\(track)\(mark) "
        let budget = 12 - head.utf8.count
        let clipped =
            name.utf8.count <= budget
            ? name : String(decoding: name.utf8.prefix(max(0, budget)), as: UTF8.self)
        // クリップ境界がスペースを跨ぐと尻尾に空白が残る — 見た目だけの話だが掃く
        return "\(head)\(clipped)".trimmingCharacters(in: .whitespaces)
    }

    /// 冊 1 冊分（実機の置き場所 + 名前 + 32 席 + ボタン）
    struct Book {
        let setupIndex: Int
        let name: String
        let knobs: [RotoMidiSetup.Knob]
        let buttons: [RotoMidiSetup.Button]
    }

    /// 全冊。INST ×2 が先頭、MIXER ×2 が SETUP 05/06。
    /// - Parameters:
    ///   - slotNames: スロット 1-64 の表示名（焼き時点のスナップショット）
    ///   - slotColors: スロットのトラックカラー（nil = バンク色 36-39 の既定）
    ///   - seatLabels: INST 冊のライブラベル（CC → 選択スロットの割当名。
    ///     無い席は正典ラベル "P1-1 CC0"）
    ///   - seatColor: INST 冊の席色（選択スロットのトラックカラー。
    ///     nil = ページ色 28-35 の既定）
    ///   - seatCellColors: 席単位の色上書き（CC → 色。trackCells — 「Cutoff は
    ///     赤」の役割色）。優先順は **席色 > トラックカラー > ページ色**
    ///   - assignedSeatsOnly: true = INST 冊は**割当のある席だけ**
    ///     （直接焼き用 — 残り席は allRequests が clear で埋める。
    ///     mako 指摘 2026-08-12「L02 INST はゴミが多い」）。
    ///     false = 全席を正典ラベルで（JSON 控えの基準形）
    ///   - selectedTrack: 選択トラック番号（1 始まり）。INST 冊の冊名に
    ///     後置され MAIN LCD に出る + MIXER 冊の選択席の「>」印の位置。
    ///     nil = ベース名のまま・印なし（JSON 控え）
    static func books(
        slotNames: [String],
        slotColors: [UInt8?] = [],
        seatLabels: [Int: String] = [:],
        seatColor: UInt8? = nil,
        seatCellColors: [Int: UInt8] = [:],
        assignedSeatsOnly: Bool = false,
        selectedTrack: Int? = nil,
        selectButtonColor: UInt8 = Roto.Color.darkGreen
    ) -> [Book] {
        // MAIN LCD に出す inst 名（選択スロットの表示名 — 席名と同じ SSOT）
        let selectedName = selectedTrack.flatMap { track -> String? in
            slotNames.indices.contains(track - 1) ? slotNames[track - 1] : nil
        }
        let selectedSlot = selectedTrack.map { $0 - 1 }
        // 並びは配置どおり MIXER ×2 → INST ×2（SETUP 01-04。mako 裁定
        // 2026-08-13「SELECT の並び、MIXER / MIXER+ / INST / INST+」）。
        // ボタンは MIXER 冊の Track 直接選択だけ（RK 冊切替は同日オミット）
        return [
            Book(
                setupIndex: mixerSetup1,
                name: "MIXER-",
                knobs: mixerKnobs(
                    names: slotNames, colors: slotColors,
                    selectedSlot: selectedSlot, half: 0),
                buttons: mixerSelectButtons(color: selectButtonColor, half: 0)),
            Book(
                setupIndex: mixerSetup2,
                name: "MIXER+",
                knobs: mixerKnobs(
                    names: slotNames, colors: slotColors,
                    selectedSlot: selectedSlot, half: 1),
                buttons: mixerSelectButtons(color: selectButtonColor, half: 1)),
            Book(
                setupIndex: instSetup1,
                name: instBookName(
                    set: 1, selectedTrack: selectedTrack, trackName: selectedName),
                knobs: seatKnobs(
                    half: 0, labels: seatLabels, color: seatColor,
                    cellColors: seatCellColors, onlyAssigned: assignedSeatsOnly),
                buttons: []),
            Book(
                setupIndex: instSetup2,
                name: instBookName(
                    set: 2, selectedTrack: selectedTrack, trackName: selectedName),
                knobs: seatKnobs(
                    half: 1, labels: seatLabels, color: seatColor,
                    cellColors: seatCellColors, onlyAssigned: assignedSeatsOnly),
                buttons: []),
        ]
    }

    /// **MIXER 冊のボタン 1-8 = 真上のノブのスロットを直接選択**（PUSH、
    /// ch2 CC 64+スロット。mako 裁定 2026-08-13「MIXER の RK は、Track の
    /// 直接選択に使いたい」— ミュート TOGGLE を置き換え。ミュートは UI に残る）。
    /// 選択で INST 冊のライブラベルと MAIN LCD の #n が追従するので、
    /// **MIXER で選んで SEL で INST へ**の音作りループが機材だけで回る。
    /// PUSH なので LED は押下中の白フラッシュだけ — 選択中の常時表示は
    /// できない（ボタン LED は外から動かせない実測 2026-08-12）。
    /// 「いまどれか」は MAIN LCD の #n が担う
    static func mixerSelectButtons(color: UInt8, half: Int = 0) -> [RotoMidiSetup.Button] {
        (0..<mixerSlotCount).map { position in
            let slot = half * mixerSlotCount + position
            return RotoMidiSetup.Button(
                controlIndex: position,
                channel: mixerChannel,
                cc: mixerButtonCCBase + slot,
                // **最小表現**（mako 裁定 2026-08-13「上にも書いてあるし、下は
                // 最小表現で良いよ」— 名前は真上のノブ LCD に出ているので、
                // ボタンはトラック番号だけ）
                name: "T\(slot + 1)",
                // 地色は設定（rotoColors.selectButton — mako 裁定 2026-08-13
                // 「設定項目にしよう」。既定は暗緑 darkGreen）
                colorScheme: color,
                ledOn: 13,  // 白 — 押下フラッシュ
                ledOff: 70,  // 黒（消灯）
                toggle: false)
        }
    }

    /// ミキサー冊の 32 席（half 0 = T1-32 / half 1 = T33-64 — Ladyland の
    /// Track 64 に MIXER 2 冊で対応）。ノブ位置 = 冊内位置、CC = **通し**の
    /// スロット番号（ch2）。
    /// **選択席は席名の頭に「>」**（mako 経緯 2026-08-13: 二段目の色は
    /// プロトコルに欄が無く、地色ハイライトは「色がありすぎて判別できない」—
    /// トラックカラーの海に埋もれた。**色ではなく位置固定の記号**で示す）。
    /// 地色は**トラックカラー > バンク色**のまま。選択が変わると差分焼きが
    /// 旧席・新席の名前 2 席だけ焼き直す。バンク（= ページ）色は淡色帯の
    /// 残り 36-39 で席冊（28-35）と被らない（両冊で同じ帯を繰り返す）
    static func mixerKnobs(
        names: [String], colors: [UInt8?] = [],
        selectedSlot: Int? = nil, half: Int = 0
    ) -> [RotoMidiSetup.Knob] {
        (0..<mixerSlotCount).map { position in
            let slot = half * mixerSlotCount + position
            let name = names.indices.contains(slot) ? names[slot] : "T\(slot + 1)"
            let marked = slot == selectedSlot ? ">\(name)" : name
            let trackColor = colors.indices.contains(slot) ? colors[slot] : nil
            return RotoMidiSetup.Knob(
                controlIndex: position,
                channel: mixerChannel,
                cc: slot,
                name: String(decoding: marked.utf8.prefix(RotoAdmin.nameLength), as: UTF8.self),
                colorScheme: trackColor ?? UInt8(36 + position / KnobPages.perPage))
        }
    }

    /// INST 冊の席色の解決 — **焼きと UI 表示（INST マトリクス）の単一ソース**。
    /// 優先順: **席色（trackCells）> トラックカラー > ページ色**
    /// （mako 要望 2026-08-12「ノブ毎の色」— LCD の地は 1 色なので全体の地色。
    /// 表示と焼きの解決が別物だと「画面の色と実機の色がズレる」— 実例
    /// 2026-08-12 mako 報告「トラックカラーが載らない」）
    static func seatColor(
        cc: Int, cellColors: [Int: UInt8], trackColor: UInt8?
    ) -> UInt8 {
        // ページの色は淡色帯（帯 3 = palette 28-40）から 1 色ずつ。
        // 淡色セットは B 案「帯をそのまま使う」で決着済み（mako 裁定 2026-08-07）
        cellColors[cc] ?? trackColor
            ?? UInt8(28 + (KnobPages.page(forCC: cc) ?? 0) % KnobPages.pageCount)
    }

    /// 席冊の 32 席。**席 = CC 番号そのもの**（KnobPages 正典）— 前半冊の
    /// ノブ位置 p は CC p、後半冊は CC (32 + p) を送る。
    /// 名前は**ライブラベル（選択スロットの割当名）> 正典ラベル**、
    /// 色は `seatColor`（席色 > トラックカラー > ページ色）。
    /// onlyAssigned = true なら割当のある席だけ（残りは呼び手が clear で埋める）
    static func seatKnobs(
        half: Int, labels: [Int: String] = [:], color: UInt8? = nil,
        cellColors: [Int: UInt8] = [:], onlyAssigned: Bool = false
    ) -> [RotoMidiSetup.Knob] {
        (0..<pagesPerSetup * KnobPages.perPage).compactMap { position in
            let cc = half * pagesPerSetup * KnobPages.perPage + position
            if onlyAssigned, labels[cc] == nil { return nil }
            let name = labels[cc] ?? "\(KnobPages.label(forCC: cc) ?? "?") CC\(cc)"
            return RotoMidiSetup.Knob(
                controlIndex: position,
                channel: seatChannel,
                cc: cc,
                name: String(decoding: name.utf8.prefix(RotoAdmin.nameLength), as: UTF8.self),
                colorScheme: seatColor(cc: cc, cellColors: cellColors, trackColor: color))
        }
    }

    // MARK: - 経路 1: 直接焼き（アドミンポート）

    /// 差分焼きの比較キー（冊 × 種別 × 席）。Codable なのは影の永続化のため
    /// （`RotoDiffShadow` — 再起動しても差分焼きが即効く）
    struct SeatKey: Hashable, Codable {
        let setup: Int
        let kind: Kind
        let control: Int

        enum Kind: String, Hashable, Codable { case name, knob, button }
    }

    /// 全冊の書き込みリクエストを列挙する — **全焼きと差分焼きの単一ソース**。
    /// 比較はリクエストのバイト列そのもので行う(構造体の同値ではなく
    /// 「実機に書かれるもの」を比べる — 生成器の変更も自然に差分になる)。
    ///
    /// **全席 = set XOR clear**(mako 指摘 2026-08-12「L02 INST はゴミが多い。
    /// まっさらから作り直したほうがいい」): 3 冊 × ノブ 32 + ボタン 32 の全席が
    /// 必ず載り、期待する席は set・それ以外は明示的に clear。焼くこと自体が
    /// まっさら化なので、過去の実験の残骸が構造的に消える。割当を外した席も
    /// set → clear のバイト列変化として差分焼きが拾う
    static func allRequests(
        slotNames: [String],
        slotColors: [UInt8?] = [],
        seatLabels: [Int: String] = [:],
        seatColor: UInt8? = nil,
        seatCellColors: [Int: UInt8] = [:],
        selectedTrack: Int? = nil,
        selectButtonColor: UInt8 = Roto.Color.darkGreen
    ) -> [(key: SeatKey, request: [UInt8])] {
        var requests: [(key: SeatKey, request: [UInt8])] = []
        let books = books(
            slotNames: slotNames, slotColors: slotColors,
            seatLabels: seatLabels, seatColor: seatColor,
            seatCellColors: seatCellColors,
            assignedSeatsOnly: true, selectedTrack: selectedTrack,
            selectButtonColor: selectButtonColor)
        let seatCount = pagesPerSetup * KnobPages.perPage
        for book in books {
            let setup = book.setupIndex
            requests.append((
                SeatKey(setup: setup, kind: .name, control: 0),
                RotoAdmin.setSetupName(index: setup, name: book.name)
            ))
            let knobs = Dictionary(
                uniqueKeysWithValues: book.knobs.map { ($0.controlIndex, $0) })
            for position in 0..<seatCount {
                requests.append((
                    SeatKey(setup: setup, kind: .knob, control: position),
                    knobs[position].map {
                        RotoAdmin.setKnobConfig(setup: setup, control: position, knob: $0)
                    } ?? RotoAdmin.clearControl(setup: setup, button: false, control: position)
                ))
            }
            let buttons = Dictionary(
                uniqueKeysWithValues: book.buttons.map { ($0.controlIndex, $0) })
            for position in 0..<seatCount {
                requests.append((
                    SeatKey(setup: setup, kind: .button, control: position),
                    buttons[position].map {
                        RotoAdmin.setSwitchConfig(setup: setup, button: $0)
                    } ?? RotoAdmin.clearControl(setup: setup, button: true, control: position)
                ))
            }
        }
        // 掃除冊 — 冊名を工場既定へ戻し、全席 clear（実験残骸の墓掃除）
        for setup in scrubSetups {
            requests.append((
                SeatKey(setup: setup, kind: .name, control: 0),
                RotoAdmin.setSetupName(
                    index: setup, name: String(format: "SETUP %02d", setup + 1))
            ))
            for position in 0..<seatCount {
                requests.append((
                    SeatKey(setup: setup, kind: .knob, control: position),
                    RotoAdmin.clearControl(setup: setup, button: false, control: position)
                ))
                requests.append((
                    SeatKey(setup: setup, kind: .button, control: position),
                    RotoAdmin.clearControl(setup: setup, button: true, control: position)
                ))
            }
        }
        return requests
    }

    /// 全冊（冊名 + 96 席）をシリアルで直接焼く。**呼び手は main 以外で呼ぶ**
    /// （ブロッキング I/O。全体で数秒 — その間実機の CC は止まる）。
    /// 返り値は結果の 1 行（UI の結果表示用）と、焼いたリクエスト一覧
    /// （差分焼きの影 `RotoDiffShadow` の初期化に使う）
    static func burn(
        slotNames: [String],
        slotColors: [UInt8?] = [],
        seatLabels: [Int: String] = [:],
        seatColor: UInt8? = nil,
        seatCellColors: [Int: UInt8] = [:],
        selectedTrack: Int? = nil,
        selectButtonColor: UInt8 = Roto.Color.darkGreen
    ) throws -> (summary: String, requests: [(key: SeatKey, request: [UInt8])]) {
        let requests = allRequests(
            slotNames: slotNames, slotColors: slotColors,
            seatLabels: seatLabels, seatColor: seatColor,
            seatCellColors: seatCellColors,
            selectedTrack: selectedTrack, selectButtonColor: selectButtonColor)
        // フレームは `5A family sub …` — sub（index 2）が 0x09 なら clear
        let cleared = requests.count { $0.request.count > 2
            && $0.request[2] == RotoAdmin.Midi.clearControlConfig }
        let summary = try RotoAdminPort.withPort { session in
            for (_, request) in requests {
                try session.configUpdate(request)
            }
            return "\(bookCount) 冊: 設定 \(requests.count - bookCount - cleared) 席"
                + " + 掃除 \(cleared) 席（FW \(session.version.description)）"
        }
        return (summary, requests)
    }

    /// 差分焼きの失敗の区別 — **影の扱いが変わる**ので呼び手が見る。
    /// nothingWritten = 1 件も書く前に失敗（ポート使用中・探索失敗）—
    /// 実機は無傷なので影を捨てる必要はない（リトライで足りる）。
    /// partiallyWritten = 途中まで書けた — どこまで入ったか信用できないので
    /// 影ごと捨てて全焼きで再出発
    enum BurnDiffError: Error {
        case nothingWritten(underlying: Error)
        case partiallyWritten(written: Int, underlying: Error)
    }

    /// 差分だけをシリアルで撃つ（変わった席が少なければ数百 ms — 全焼きの
    /// 数秒に対して、曲中の選択切替にも耐える短さ。それでも CC は止まるので
    /// 呼び手がデバウンスで束ねる）
    static func burnDiff(_ requests: [[UInt8]]) throws -> String {
        var written = 0
        do {
            return try RotoAdminPort.withPort { session in
                for request in requests {
                    try session.configUpdate(request)
                    written += 1
                }
                return "\(requests.count) 席を差分焼き（FW \(session.version.description)）"
            }
        } catch {
            throw written == 0
                ? BurnDiffError.nothingWritten(underlying: error)
                : BurnDiffError.partiallyWritten(written: written, underlying: error)
        }
    }

    // MARK: - 経路 2: Export All 互換 JSON

    /// ⚠️ ライブラベル（seatLabels / seatColor）は**控えに入れない** —
    /// あれは選択スロット依存の一時状態で、Import で戻す基準形は
    /// 正典ラベル + ページ色。トラックカラーは永続的な席の属性なので入れる
    static func setups(
        slotNames: [String], slotColors: [UInt8?] = []
    ) -> [(fileName: String, contents: String)] {
        books(slotNames: slotNames, slotColors: slotColors).map { book in
            (
                "\(book.name).json",
                RotoMidiSetup.document(
                    name: book.name, index: book.setupIndex,
                    knobs: book.knobs, buttons: book.buttons)
            )
        }
    }

    /// Export All と同じ形（`ROTO-CONTROL <日時>/MIDI/*.json`）で書く。
    /// 返り値は作ったバックアップフォルダ
    static func write(
        into parent: URL, slotNames: [String], slotColors: [UInt8?] = [],
        at date: Date = Date()
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = parent.appendingPathComponent(
            "ROTO-CONTROL \(formatter.string(from: date))", isDirectory: true)
        let midi = folder.appendingPathComponent("MIDI", isDirectory: true)
        try FileManager.default.createDirectory(at: midi, withIntermediateDirectories: true)
        for setup in setups(slotNames: slotNames, slotColors: slotColors) {
            try setup.contents.write(
                to: midi.appendingPathComponent(setup.fileName),
                atomically: true, encoding: .utf8)
        }
        return folder
    }
}
