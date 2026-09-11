//! 割当一覧の構造導出 — 純関数（テスト対象）。
//!
//! mako 裁定 2026-08-02: **並びは割当セル順**（プラグイン作者の定義順ではない）。
//! 行番号 1-8 が物理ノブの 1-8 とそのまま一致するので、ノブ 3 番を触りながら
//! 3 行目を見れば済む — ノブストリップと同じ読み方ができる。
//!
//! これに伴い **8×16 のマトリクスは廃止**（mako 裁定「なくす」）。
//! セル順に並べた時点で一覧がマトリクスの役割を吸収し、「大事なものを P1 へ
//! 引っ越す」という主操作が**行の並べ替え**として自然に表現できる。
//!
//! セクションの切り方はプラグインのグループではなく**ページ（= 物理のノブ 1 面）**。
//! グループ名は行の添え物へ格下げ（並びを壊さずに系統が分かる）。

import AudioToolbox
import Foundation

/// パラメータ現在値の整形 — 純関数（テスト対象）。
///
/// ⚠️ **`AUParameter.string(fromValue:)` を使ってはいけない**（実機クラッシュ
/// 2026-08-02）。AUv2 ブリッジ経由だと `AudioUnitGetProperty` でプラグイン本体に
/// 文字列変換を問い合わせに行き、**KORG のプラグイン内で null 参照して落ちる**。
/// 一覧は数十行を毎描画なぞるので踏む確率も高い。
/// 値と単位（どちらも AUParameter が保持する静的な情報）から自分で組む。
enum ParameterFormat {
    static func text(value: Float, unit: AudioUnitParameterUnit) -> String {
        switch unit {
        case .boolean:
            return value >= 0.5 ? "on" : "off"
        case .indexed:
            return String(Int(value.rounded()))
        case .percent:
            return "\(number(value)) %"
        case .decibels:
            return "\(number(value)) dB"
        case .hertz:
            // 1kHz を超えたら kHz に畳む（1.95 kHz の方が 1950 Hz より読める）
            return value >= 1000
                ? "\(number(value / 1000)) kHz" : "\(number(value)) Hz"
        case .seconds:
            return value < 1 ? "\(number(value * 1000)) ms" : "\(number(value)) s"
        case .milliseconds:
            return "\(number(value)) ms"
        case .cents, .relativeSemiTones:
            return "\(number(value)) ct"
        case .midiNoteNumber, .midiController:
            return String(Int(value.rounded()))
        case .beats:
            return "\(number(value)) beat"
        case .ratio:
            return "\(number(value)) :1"
        default:
            return number(value)
        }
    }

    /// 桁は値の大きさに合わせる（0.42 は 0.42、1950 は 1950、-6 は -6）。
    /// **割り切れる値に無駄な小数を付けない** — 一覧は横幅が限られる
    private static func number(_ value: Float) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: abs(value) < 10 ? "%.2f" : "%.1f", value)
    }
}

/// 一覧に出すパラメータの素性（AUParameter から起こす値型 — ここが純関数の入口）
struct ParameterInfo: Equatable {
    let address: UInt64
    let name: String
    /// AUParameterTree 上の直近のグループ名（無ければ nil）
    let group: String?
    /// 書き込める = 割り当てる意味がある。読み取り専用は一覧に出さない
    let writable: Bool
}

extension ParameterInfo {
    /// AU の全パラメータを（グループ文脈付きで）列挙する — 割当パネルと
    /// INST マトリクスが同じ入口を使う（第 2 の定義を作らない）
    @MainActor
    static func list(of slot: InstrumentSlot) -> [ParameterInfo] {
        let groups = groupNames(of: slot.audioUnit?.auAudioUnit.parameterTree)
        return slot.parameterList.map { param in
            ParameterInfo(
                address: param.address,
                name: param.displayName,
                group: groups[param.address],
                writable: param.flags.contains(.flag_IsWritable))
        }
    }

    /// AUParameterTree を辿って address → 直近のグループ名を作る。
    /// `allParameters` は木を平らに潰すのでこの文脈が落ちる — 拾い直す
    static func groupNames(of tree: AUParameterTree?) -> [UInt64: String] {
        guard let tree else { return [:] }
        var map: [UInt64: String] = [:]
        func walk(_ node: AUParameterNode, enclosing: String?) {
            if let group = node as? AUParameterGroup {
                for child in group.children {
                    walk(child, enclosing: group.displayName.isEmpty ? enclosing : group.displayName)
                }
            } else if let param = node as? AUParameter {
                map[param.address] = enclosing
            }
        }
        // 根そのものの名前はグループとして扱わない
        for child in tree.children {
            walk(child, enclosing: nil)
        }
        return map
    }

    /// グループで階層に抜く用の束ね。
    /// ⚠️ **グループが 1 つしか無い機種は階層にしない** — Berlin は全部が
    /// `global` 配下なので、階層にすると「global」を 1 段潜るだけの段差になる
    static func grouped(
        _ parameters: [ParameterInfo]
    ) -> [(title: String, items: [ParameterInfo])] {
        var order: [String] = []
        var buckets: [String: [ParameterInfo]] = [:]
        for parameter in parameters where parameter.writable {
            let key = parameter.group ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(parameter)
        }
        guard order.count > 1 else {
            return [(title: "", items: order.first.flatMap { buckets[$0] } ?? [])]
        }
        return order.map { (title: $0, items: buckets[$0] ?? []) }
    }
}

enum AssignList {
    /// 一覧の 1 行。**値は持たない** — 現在値は描画時に slot から読む
    /// （構造の導出と、刻々変わる値を混ぜない）
    struct Row: Identifiable, Equatable {
        /// 割当先の Ctrl 番号。nil = 未割当セクションの行
        let cc: Int?
        /// ページ内の位置 1-8（未割当・PB は nil）
        let position: Int?
        /// 割り当てられているパラメータ。nil = 空きセル
        let address: UInt64?
        /// 表示に使う名前（別名があればそれ。KnobLabel.resolve の結果）
        let name: String?
        /// 手で付けた別名（nil = AU の実名をそのまま使っている）。
        /// 編集 UI が「別名なのか実名なのか」を区別するために持つ
        let alias: String?
        let group: String?
        /// 予約セル（keep モードの Damper など）— 割当対象外
        let reserved: Bool
        /// 物理コントローラの目印（M / E / PB）
        let badge: String?

        var id: String { cc.map { "cc\($0)" } ?? "free-\(address ?? 0)" }
        var isEmptyCell: Bool { cc != nil && address == nil && !reserved }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        /// 見出しの副題（CC 範囲など）
        let subtitle: String?
        let rows: [Row]
        var id: String { title }
    }

    /// 連番を圧縮して短く表す（`[0,2,3,4,5,6,7]` → `"0,2-7"`）。
    ///
    /// いまのページは連番（P1 = CC0-7）なのでそのまま `-` で畳まれる。
    /// かつては演奏席（CC1/11/64）が帯の中に居てページに飛びがあり、
    /// 「CC0-7」と書けなかった — **正確かつ短く**（mako 2026-08-04）は
    /// どちらの形でも保てる
    static func compactRanges(_ values: [Int]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var start = sorted[0]
        var previous = sorted[0]
        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = value
            previous = value
        }
        parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return parts.joined(separator: ",")
    }

    /// 一覧の全体構造を組む。
    ///
    /// - Keystage: **Pn → 未割当 → 演奏**（mako 要望 2026-08-06）
    /// - LPD8: K1-K8 の 1 セクション → 未割当
    static func sections(
        mappings: [FaceKnobMapping], parameters: [ParameterInfo], surface: Surface,
        pedal: PedalMode = .keep
    ) -> [Section] {
        let byCC = Dictionary(mappings.map { ($0.knob, $0) }, uniquingKeysWith: { first, _ in first })
        let infoByAddress = Dictionary(
            parameters.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })

        func row(cc: Int, position: Int?) -> Row {
            let mapping = byCC[cc]
            let info = mapping.flatMap { infoByAddress[$0.address] }
            return Row(
                cc: cc,
                position: position,
                address: mapping?.address,
                // 別名 > AU の現在名 > 割当時に控えた名前
                // （プラグインが差し替わっても手掛かりが残る）
                name: KnobLabel.resolve(
                    alias: mapping?.alias, live: info?.name, remembered: mapping?.name),
                alias: mapping?.alias,
                group: info?.group,
                reserved: surface == .keystage
                    && FaceKnobAssignment.reservedCCs(pedal: pedal).contains(cc),
                // ⚠️ **「⚠︎ MIDI 予約」バッジは 2026-08-08 に消した。**
                //
                // 前提が死んだから — あれは「危険牌は回した瞬間に楽器へ届いて
                // 音が切れる」という警告だった。⭐ **#75（`base = 0` / 64 席
                // 全部横取り）で帯の CC は何番であれ楽器に届かなくなった**
                // （`KeystageKnobs`「番号の意味は、届かなければ無関係になる」）。
                //
                // 残していると **P1 の CC0/CC7、P2 の CC10、P5 の CC32 に
                // 「起きない事故」の警告**が出る。⚠️ **脅しが嘘になると、
                // 本物の警告まで信じられなくなる**。
                //
                // ⚠️ **`isUnsafe` / `unsafeCCs` 自体は残す** — 自動割振の
                // 順序（危険牌を後ろのページへ。`FaceKnobs` の `assignableCCs`）
                // に効いていて、外すと**並びが変わる**。整理は 8/8 の後。
                //
                // ⭐ `controllerBadge`（ModWheel / Damper など役割名）は本物の
                // 情報なので残す
                badge: surface == .keystage ? FaceKnobAssignment.controllerBadge(cc) : nil)
        }

        var sections: [Section] = []

        // 未割当（書き込めるものだけ。読み取り専用は割り当てても動かない）。
        // **P1 の上に置く**（mako 要望 2026-08-04「未割り当てを P1 の上に」）—
        // 割り当てる作業は「まだ席が無いもの」が起点になるので、
        // 一番下まで捲らせない
        let assigned = Set(mappings.map(\.address))
        let free = parameters.filter { $0.writable && !assigned.contains($0.address) }
        let unassigned: Section? =
            free.isEmpty
            ? nil
            : Section(
                title: "未割当", subtitle: "\(free.count) 個",
                rows: free.map {
                    // 未割当は別名を持ちえない（別名は割当に付く）
                    Row(
                        cc: nil, position: nil, address: $0.address, name: $0.name,
                        alias: nil, group: $0.group, reserved: false, badge: nil)
                })

        switch surface {
        case .keystage:
            // ⚠️ **並びは Pn → 未割当 → 演奏**（mako 要望 2026-08-06
            // 「Pn > 未割当 > 演奏 の順に並べ替えて」）。
            //
            // **履歴**: 2026-08-04 に「固定値のやつは演奏グループに入るのが自然」で
            // **演奏を先頭**にまとめ、続いて「未割り当てを P1 の上に」で
            // **未割当を P1 の上**へ置いた。2026-08-06 にどちらも後ろへ回して
            // **実機のページを起点**にする形へ。ROTO / Keystage を繰りながら
            // 使う面なので、**いま見ているページが最初に来る**方が手数が少ない。
            //
            // ⚠️ 演奏席（Mod / Exp / Damper / PB）が**割当可能な一級市民**である
            // ことは変わらない（2026-08-01 裁定）— 動かしたのは表示の順序だけ。
            //
            // ⭐ **ページは実機のノブが送る CC そのもの** — ページ = CC ÷ 8 が
            // 唯一の正典（`KeystageKnobs`。P1 = CC0-7、mako 裁定 2026-08-07 夜
            // 「base = 0 / pageCount = 8」）。
            //
            // ⚠️ **以前は「割当可能な CC を 8 個ずつ」で切っていた**（2026-08-04）
            // が、それは**画面の都合**であって実機と対応していなかった。
            // 実機はデバイス自身のページを PAGE -/+ で進め、
            // **CC 番号がページを自己申告している**ので、そこに合わせる
            // （`KnobSelect` は KONTROL EDITOR の表示切替にすぎず、設定不要）。
            //
            // ⭐ **ROTO の SMART 面も同じ正典**（2026-08-09 統合。
            // `RotoPageLayout.smartPages = KnobPages.pages`）。かつては
            // 席プールの並びで別勘定に切っていて、LCD だけがズレたページを
            // 映していた（監査 2026-08-08 の B-1）。割当そのもの
            // （CC → パラメータ）は共有なので、どちらから触っても同じものが動く
            let allPages = KnobPages.pages
            // 使っているページ + 伸びしろ 1 ページ（何も無ければ P1 だけ）
            let lastUsed = mappings.compactMap { KnobPages.page(forCC: $0.knob) }.max() ?? -1
            let pageCount = min(allPages.count, max(1, lastUsed + 2))
            for page in 0..<pageCount {
                let cells = allPages[page]
                sections.append(
                    Section(
                        title: "P\(page + 1)",
                        subtitle: "CC" + compactRanges(cells),
                        rows: cells.enumerated().map {
                            row(cc: $0.element, position: $0.offset + 1)
                        }))
            }

            // ページの後ろに未割当 → 演奏（上記の履歴）
            if let unassigned { sections.append(unassigned) }
            sections.append(
                Section(
                    title: "演奏", subtitle: "ホイール・ペダル",
                    rows: FaceKnobAssignment.controllerCCs.map { row(cc: $0, position: nil) }))

        case .lpd8(let ccs):
            sections.append(
                Section(
                    title: "K1-K8", subtitle: "現在プログラムの CC",
                    rows: ccs.enumerated().map { row(cc: $0.element, position: $0.offset + 1) }))
        }

        // LPD8 は 1 セクションしかないので、未割当は後ろのままでよい
        if case .lpd8 = surface, let unassigned { sections.append(unassigned) }
        return sections
    }
}
