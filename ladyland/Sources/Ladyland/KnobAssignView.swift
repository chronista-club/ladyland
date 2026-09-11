//! 顔つまみ割当パネル（P4 → 2026-08-01 マトリクス → 2026-08-02 一覧へ一本化）。
//!
//! 画面右の R Area に常駐し、**選択中トラックに常時追従**する。
//!
//! mako 裁定 2026-08-02:
//!   - **並びは割当セル順** — 行番号 1-8 が物理ノブ 1-8 と一致する
//!   - **8×16 のマトリクスは廃止**（セル順の一覧がその役割を吸収する）
//!   - セクション = ページ（物理のノブ 1 面）。プラグインのグループは行の添え物
//!   - 現在値を出す / 読み取り専用は出さない
//!
//! 操作（mako 裁定 2026-08-05「ドラッグアンドドロップではなく、セレクトでリストから
//! 選ぶ方式にしたい」— **ドラッグは廃止**、タップの二段構えも畳んだ）:
//!   - 席の名前を押す   = その席に載せるパラメータを選ぶ（グループで階層に抜く）
//!   - 未割当の名前を押す = どの席へ載せるかを選ぶ（ページで階層に抜く）
//!   ⚠️ Menu のラベルは**単一の Text**に保つこと — HStack を渡すと macOS は
//!      最初の Text だけ描いて、名前も現在値も消える（実測 2026-08-05）
//!   - 同じメニューに「別名をつける」「この席を空ける」を畳む
//!   - 既に別の席にあるものを選ぶと**移動**（元の席が空く）。項目に現在地を添える
//!   - 予約セル（keep モードの Damper など）はメニューを開かない

import AVFoundation
import CreoUI
import RotoKit
import SwiftUI

/// **面** — 外部機器と、選択中の楽器を繋ぐところ
/// （mako 裁定 2026-08-06「"割り当て" もちと違う気がするな。**外部機器と、
/// （選択中の）楽器を繋ぐ面**なんだよね」→ Surface）。
///
/// ## 3 層の語彙（混ぜないこと）
///
/// | 層 | 何を指すか | 型 |
/// |---|---|---|
/// | **surface** | **機材ごとの面**。どの物理像を出すか | `Surface` / `SurfaceTab` |
/// | **assignment** | **繋ぐ行為**。何をどこへ載せるか決める | `AssignList` / `Assignable` / `fillMissingAssignments` |
/// | **mapping** | **繋がりそのもの**。1 ノブ ↔ 1 パラメータ | `FaceKnobMapping` |
///
/// 「Keystage **の割り当て**」は真だが「ROTO **の割り当て**」は嘘になる
/// （ROTO は割り当てを編集しない）。**「ROTO の面」なら真** — だから
/// フレームを面に置いた。
///
/// ⚠️ **`Surface` と `SurfaceTab` は数が違う**（2 対 3）。`Surface` は
/// **`KnobAssignPanel` が描く物理像の種類**、`SurfaceTab` は
/// **サイドバーが見せる面**で、別のものを数えている。ROTO は物理像を
/// 描かない（デバイスの設定を出す）ので `Surface` には現れない
enum Surface: Equatable {
    /// Keystage: 8 ノブ × 8 ページ（帯 CC0-63）+ 演奏レーン
    case keystage
    /// LPD8: K1-K8（現在プログラムの実 CC。GET で追従）
    case lpd8(knobCCs: [Int])
}

struct KnobAssignPanel: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot

    var surface: Surface = .keystage

    /// **実機がいま出しているページ**（0 始まり。nil = 追従しない面）。
    /// ROTO / Keystage を繰ると変わる — 読むだけで、送信経路には触らない
    var activePage: Int?

    /// activePage が**実機由来か**（ノブ CC の自己申告 or ROTO 接続中）。
    /// ⚠️ 機材ゼロでは false — ページ追従の見出し色は残すが「実機」バッジは
    /// 出さない（監査 2026-08-09 C-1: 未接続なのに実機を名乗っていた）
    var activePageIsLive: Bool = true

    /// ダンパーペダルの役割（assign なら CC64 も割当セルになる）
    var pedal: PedalMode = .keep

    /// 割当変更を AppState に伝える（ルーターの横取り CC 集合を同期する）
    let onChanged: () -> Void

    /// **セルの色**（mako 要望 2026-08-05「小さい色のアイコンをおいて、
    /// コンテクストメニューでパレットを開いて、即時更新できるように」）。
    /// AppState を直接持たず、読み書きを閉じ込めた 2 つの口だけ受け取る —
    /// このパネルは LPD8 面でも使い回すので、ROTO への依存を最小にする
    var cellColor: ((Int) -> UInt8)?
    var setCellColor: ((Int, UInt8?) -> Void)?
    /// 空きセルに出る色（設定 → ROTO で決める）
    var emptyColor: UInt8 = 0

    /// **この席の既定**の保存 / 復元（mako 要望 2026-08-06）。
    /// パネルは LPD8 面でも使い回すので、`AppState` を直接持たず口だけ受け取る
    var onSetDefault: (() -> Void)?
    var onLoadDefault: (() -> Void)?
    /// 既定を覚えているか（load を押せるかの判定）
    var hasDefault = false

    /// **この席の MAIN LCD の地**（読み書き。ROTO 面でだけ出す）
    var mainLcdColor: (() -> UInt8)?
    var setMainLcdColor: ((UInt8?) -> Void)?


    /// 別名を編集中のセル（nil = 編集していない）と入力中の文字
    @State private var editingCC: Int?
    @State private var aliasDraft = ""

    /// 畳んでいるセクション（title で覚える）。
    /// **既定は「割当があるページだけ開く」** — 全ページぶん開くと
    /// 行が並んで目的の行まで遠い（mako 要望 2026-08-04
    /// 「Page 毎に Accordion できる UI にしよう」）
    @State private var collapsed: Set<String> = []

    /// 初回だけ既定の畳み方を決める（以後はユーザーの開閉を尊重する）
    @State private var didSetInitialCollapse = false

    /// 追従で最後に開いたページ。**同じページに留まっている間は何もしない**
    @State private var followedPage: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack(spacing: CreoUITokens.spacingS) {
                Text(slot.displayName ?? "（空トラック — ロードすると全パラメータが並ぶ）")
                    .font(LadylandFont.body.bold())
                    .foregroundColor(
                        slot.displayName == nil ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // **この席の MAIN LCD の地**（mako 要望 2026-08-06「MAIN LCD の色
                // ページカラー同様に、プラグイン側に持たせて」）。右クリックで選ぶ —
                // セル色と同じ作法なので、覚え直さなくていい
                if surface == .keystage, mainLcdColor != nil {
                    mainLcdChip
                }

                // **この席の既定**（mako 要望 2026-08-06「set default / load default が欲しい」）。
                // ライブ前に基準を覚えておき、演奏で崩したら 1 手で戻す。
                // draft と違って**何度でも戻れる**のが要点
                if slot.audioUnit != nil, onSetDefault != nil {
                    Button("set") { onSetDefault?() }
                        .buttonStyle(.borderless)
                        .font(LadylandFont.caption)
                        .help("いまの音色と割当を、この席の既定として覚える")

                    Button("load") { onLoadDefault?() }
                        .buttonStyle(.borderless)
                        .font(LadylandFont.caption)
                        .foregroundColor(
                            hasDefault ? theme.brandPrimary : theme.textTertiary)
                        .disabled(!hasDefault)
                        .help(
                            hasDefault
                                ? "覚えた既定へ戻す（何度でも戻れる）"
                                : "まだ既定を覚えていない")
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            // 畳んでいるページは行を描かない（ドロップ先にもならない）
                            if !collapsed.contains(section.title) {
                                ForEach(section.rows) { row in
                                    rowView(row)
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // ⚠️ **実機のページに追従して開く**（mako 要望 2026-08-06
            // 「Page のインデックスに合わせて、ページと割り当てパラメータを
            // 連動させたい」）。
            //
            // ⚠️ **手で畳んだ状態を上書きし続けない**。追従するのは
            // **ページが変わった瞬間の 1 回だけ**で、同じページに留まっている
            // 間は何もしない — そうしないと別のページを見ながら作業できなくなる
            // （開き直しが毎 tick 走ると、畳んでも即座に開く）。
            //
            // 開くのは対象ページだけで、**他のページは畳まない** — 手で開いた
            // ものを勝手に閉じるのも同じ種類の押し付けになる
            .onChange(of: activePage) { _, page in
                guard let page, page != followedPage else { return }
                followedPage = page
                collapsed.remove("P\(page + 1)")
            }
            .onAppear {
                guard !didSetInitialCollapse else { return }
                didSetInitialCollapse = true
                followedPage = activePage
                // 割当が 1 つも無いページは畳んでおく（未割当セクションは開く）
                collapsed = Set(
                    sections
                        .filter { section in
                            section.rows.contains { $0.cc != nil }
                                && !section.rows.contains { $0.address != nil }
                        }
                        .map(\.title))
                // 実機が出しているページは畳まない（起動直後からそこを見たい）
                if let activePage { collapsed.remove("P\(activePage + 1)") }
            }

            Text(hint)
                .font(LadylandFont.caption)
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        surface == .keystage
            ? "名前を押すと一覧から選べる（別名・席を空けるのも同じメニュー）。M = Mod、E = Exp、PB = ピッチベンド — 未割当なら楽器へ素通し"
            : "LPD8 の K1-K8（現在プログラムの CC、GET で追従）。名前を押して一覧から選ぶ — 割当外の CC はドラム楽器へ素通し"
    }

    // MARK: - 構造（純関数へ委ねる）

    private var parameters: [ParameterInfo] {
        ParameterInfo.list(of: slot)
    }

    private var sections: [AssignList.Section] {
        AssignList.sections(
            mappings: slot.knobMappings, parameters: parameters, surface: surface, pedal: pedal)
    }

    // groupNames は ParameterInfo.groupNames へ共有化（INST マトリクスと共用）

    // MARK: - 描画

    /// **実機がいま出しているページか**（見出しに印を出す）
    private func isActivePage(_ section: AssignList.Section) -> Bool {
        guard let activePage else { return false }
        return section.title == "P\(activePage + 1)"
    }

    private func sectionHeader(_ section: AssignList.Section) -> some View {
        let isCollapsed = collapsed.contains(section.title)
        // 「何個埋まっているか」を畳んだままでも分かるようにする
        let filled = section.rows.filter { $0.address != nil }.count
        let assignable = section.rows.filter { !$0.reserved }.count
        return HStack(spacing: CreoUITokens.spacingS) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(LadylandFont.chipHeading)
                .foregroundColor(theme.textTertiary)
                .frame(width: 10)
            Text(section.title)
                .font(LadylandFont.caption.bold())
                // **実機が出しているページは色で言う** — 開いているだけだと、
                // 手で他のページも開いたときにどれが実機か分からなくなる
                .foregroundColor(
                    isActivePage(section) ? theme.brandPrimary : theme.textSecondary)
            if isActivePage(section), activePageIsLive {
                CreoBadge("実機", variant: .brand, size: .s, shape: .square)
            }
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(LadylandFont.caption)
                    .foregroundColor(theme.textTertiary)
            }
            Spacer()
            if assignable > 0 {
                Text("\(filled)/\(assignable)")
                    .font(LadylandFont.caption)
                    .foregroundColor(
                        filled == 0 ? theme.textTertiary : theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.surfaceBgBase)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                collapsed.remove(section.title)
            } else {
                collapsed.insert(section.title)
            }
        }
    }

    /// 1 行 = 1 席（または未割当のパラメータ 1 つ）。
    ///
    /// **名前のところがプルダウン**（mako 裁定 2026-08-05「ドラッグアンドドロップ
    /// ではなく、セレクトでリストから選ぶ方式にしたい」）
    private func rowView(_ row: AssignList.Row) -> some View {
        // 座標欄の文字（ページ行は位置番号、演奏席は役割名）。
        // ⚠️ 式のまま書くと型推論が破綻する（"unable to type-check in
        // reasonable time"）ので、先に String へ落としておく
        let slotText: String = {
            if let position = row.position { return String(position) }
            guard let cc = row.cc else { return "" }
            return FaceKnobAssignment.controllerName(cc) ?? ""
        }()

        return HStack(spacing: CreoUITokens.spacingS) {
            // 位置番号（物理ノブ 1-8 とそのまま対応）。
            // 演奏席には位置が無いので**役割名**を出す — ここを一律「PB」と
            // 書いていたので Mod も Exp も Damper も PB に見えていた。
            //
            // 幅はセクションごとに変える: 演奏席は名前が長く、ページ側は 1 桁。
            // **同じセクションの中では揃う**ので違和感は出ない（演奏セクションは
            // 全行が position なし、ページ側は全行が position あり）
            Text(slotText)
                .font(LadylandFont.captionNumber)
                .foregroundColor(theme.textTertiary)
                .frame(width: slotText.count > 2 ? 76 : 18, alignment: .trailing)

            if let badge = row.badge {
                Text(badge)
                    .font(LadylandFont.chipBold)
                    .foregroundColor(theme.brandPrimary)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }

            // **名前のところがプルダウン**（席なら「何を載せるか」、
            // 未割当なら「どの席へ」）。
            //
            // ⚠️ ラベルに `HStack` を渡してはいけない — macOS は**最初の Text だけ**を
            // 取り出して描画する（実測 2026-08-05: 位置番号しか残らず、名前も現在値も
            // 消えた。未割当行は位置が空文字なので行ごと見えなくなった）。
            // **ラベルは単一の Text に保ち**、他の要素は Menu の外に並べる
            if editingCC != nil, editingCC == row.cc {
                // 別名の編集中だけは素の TextField（Menu のラベルは打鍵を奪う）
                aliasField(row)
            } else if row.reserved {
                nameText(row)
            } else {
                Menu {
                    assignMenu(row)
                } label: {
                    nameText(row)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if let group = row.group {
                Text(group)
                    .font(LadylandFont.chip)
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // 現在値（構造ではなく刻々変わる値なので、ここで slot から読む）
            if let address = row.address, let text = valueText(address) {
                Text(text)
                    .font(LadylandFont.captionNumber)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            // **実機に出ている色**（mako 要望 2026-08-05）。右クリックで選び直す。
            // ⚠️ Menu の**外**に置く — ラベルの中に入れると行のプルダウンが先に
            // 開いて、色のコンテクストメニューへ辿り着けない
            if surface == .keystage, cellColor != nil, let cc = row.cc,
                row.position != nil, !row.reserved
            {
                colorChip(cc: cc, hasMapping: row.address != nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(rowHelp(row))
    }

    /// 行の名前 — **プルダウンのラベルを兼ねる**ので、単一の Text に保つ
    private func nameText(_ row: AssignList.Row) -> some View {
        Text(rowLabel(row))
            .font(LadylandFont.caption)
            .lineLimit(1)
            .foregroundColor(rowColor(row))
            // 別名が付いている印（実名と区別が付かないと戻せない）
            .italic(row.alias != nil)
    }

    /// 別名の編集欄（design/06 §8 追補 2026-08-03）。AU が `Edit 3` としか名乗らない
    /// プラグインでは、ここで付けた名前が ROTO の LCD とノブストリップの唯一の
    /// 手掛かりになる。**ライブ前の設営で一番よく触る場所**
    @ViewBuilder
    private func aliasField(_ row: AssignList.Row) -> some View {
        if let cc = row.cc {
            TextField(row.name ?? "", text: $aliasDraft)
                .textFieldStyle(.plain)
                .font(LadylandFont.caption)
                .foregroundColor(theme.brandPrimary)
                .onSubmit { commitAlias(cc) }
                .onExitCommand { editingCC = nil }
        }
    }

    /// 行のプルダウン。**席の行**なら「何を載せるか」、**未割当の行**なら
    /// 「どの席へ載せるか」— 同じ操作で両方向から辿れる
    @ViewBuilder
    private func assignMenu(_ row: AssignList.Row) -> some View {
        if let cc = row.cc {
            ForEach(groupedParameters, id: \.title) { group in
                if group.title.isEmpty {
                    ForEach(group.items, id: \.address) { parameterButton($0, to: cc) }
                } else {
                    // 長い一覧は**グループで階層に抜く** — Lisbon は 67 個ある
                    Menu(group.title) {
                        ForEach(group.items, id: \.address) { parameterButton($0, to: cc) }
                    }
                }
            }
            if row.address != nil {
                Divider()
                Button("別名をつける…") { beginAliasEdit(row) }
                Button("この席を空ける") { clear(row) }
            }
        } else if let address = row.address,
            let info = parameters.first(where: { $0.address == address })
        {
            ForEach(assignableSections, id: \.id) { section in
                Menu(section.title) {
                    ForEach(section.rows.filter { $0.cc != nil && !$0.reserved }, id: \.id) { cell in
                        cellButton(cell, for: info)
                    }
                }
            }
        }
    }

    /// パラメータ 1 個の項目。**いまどこに載っているか**を添える —
    /// 選ぶと移動（元の席が空く）ので、何が動くのか選ぶ前に分かる。
    ///
    /// ⚠️ **タイトル文字列の `Button` を使う**。`label:` に `if/else` や `Label` を
    /// 置くと、メニュー項目（`NSMenuItem`）へ落ちる過程で描かれず、
    /// **サブメニューが空のまま開かなくなる**（実測 2026-08-05）
    private func parameterButton(_ info: ParameterInfo, to cc: Int) -> some View {
        let current = slot.knobMappings.first { $0.address == info.address }
        let mark = current?.knob == cc ? "✓ " : ""
        let elsewhere = current.map { $0.knob != cc ? " · \(label(for: $0.knob))" : "" } ?? ""
        return Button(mark + info.name + elsewhere) { assign(info, to: cc) }
    }

    /// 席 1 個の項目（未割当の行から選ぶとき）。空きか、何が入っているかを出す
    private func cellButton(_ cell: AssignList.Row, for info: ParameterInfo) -> some View {
        let position = cell.position.map(String.init) ?? ""
        let occupant = cell.isEmptyCell ? " — 空き" : (cell.name.map { " — \($0)" } ?? "")
        return Button(position + occupant) {
            guard let cc = cell.cc else { return }
            assign(info, to: cc)
        }
    }

    /// グループごとに畳んだパラメータ（プルダウンの階層に使う）。
    /// グループを持たない機種は 1 段のまま（Marseille は 11 個）
    private var groupedParameters: [(title: String, items: [ParameterInfo])] {
        ParameterInfo.grouped(parameters)
    }

    /// 席を持つセクション（未割当セクションは行き先にならないので外す）
    private var assignableSections: [AssignList.Section] {
        sections.filter { section in section.rows.contains { $0.cc != nil && !$0.reserved } }
    }

    private func assign(_ info: ParameterInfo, to cc: Int) {
        guard !FaceKnobAssignment.reservedCCs(pedal: pedal).contains(cc) || surface != .keystage
        else { return }
        // **既存の両方向競合は取り除かれる** = 別の席にあったものは移動になる
        // （mako 裁定 2026-08-05「移動（元の席が空く）」）
        slot.knobMappings = FaceKnobAssignment.assigning(
            slot.knobMappings, knob: cc, address: info.address, name: info.name)
        onChanged()
    }

    private func clear(_ row: AssignList.Row) {
        guard let address = row.address else { return }
        slot.knobMappings = FaceKnobAssignment.removing(slot.knobMappings, address: address)
        onChanged()
    }

    /// 別名の編集を始める（下書きは現在の別名だけ入れる — 実名は
    /// プレースホルダに出すので、空のまま確定すれば実名に戻る）
    private func beginAliasEdit(_ row: AssignList.Row) {
        guard let cc = row.cc, row.address != nil, !row.reserved else { return }
        aliasDraft = row.alias ?? ""
        editingCC = cc
    }

    private func commitAlias(_ cc: Int) {
        slot.knobMappings = FaceKnobAssignment.aliasing(
            slot.knobMappings, knob: cc, alias: aliasDraft)
        editingCC = nil
        onChanged()
    }

    /// **MAIN LCD の地**の印（ヘッダ）。右クリックでパレット。
    /// セルの色チップと同じ見た目・同じ操作 — 覚え直さなくていい
    @ViewBuilder
    private var mainLcdChip: some View {
        let index = mainLcdColor?() ?? 0
        let rgb = Roto.Color.palette[Int(index) % Roto.Color.palette.count]
        RoundedRectangle(cornerRadius: 2)
            .fill(
                Color(
                    red: Double((rgb >> 16) & 0xFF) / 255,
                    green: Double((rgb >> 8) & 0xFF) / 255,
                    blue: Double(rgb & 0xFF) / 255)
            )
            .frame(width: 12, height: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(theme.textTertiary.opacity(0.5), lineWidth: 0.5)
            )
            .help("MAIN LCD の地（右クリックで選ぶ。⚠️ 文字は白固定なので暗い色を）")
            .contextMenu {
                ForEach(Array(Roto.Color.matrix().enumerated()), id: \.offset) { _, row in
                    Menu(hueRowLabel(row)) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, candidate in
                            if let candidate {
                                Button(colorLabel(candidate)) { setMainLcdColor?(candidate) }
                            }
                        }
                    }
                }
                Divider()
                Button("設定の既定に戻す") { setMainLcdColor?(nil) }
            }
    }

    /// 実機に出ている色の小さな印。**右クリックでパレットを開く**。
    ///
    /// 割当が無い行は `empty`（黒）が出るので、そちらを映す —
    /// 「今こう見えている」がそのまま分かるのが要点
    @ViewBuilder
    private func colorChip(cc: Int, hasMapping: Bool) -> some View {
        let index = hasMapping ? (cellColor?(cc) ?? 0) : emptyColor
        let rgb = Roto.Color.palette[Int(index)]
        RoundedRectangle(cornerRadius: 2)
            .fill(
                Color(
                    red: Double((rgb >> 16) & 0xFF) / 255,
                    green: Double((rgb >> 8) & 0xFF) / 255,
                    blue: Double(rgb & 0xFF) / 255)
            )
            .frame(width: 10, height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(theme.textTertiary.opacity(0.5), lineWidth: 0.5)
            )
            .opacity(hasMapping ? 1 : 0.4)
            .help(
                hasMapping
                    ? "ROTO の LCD に出る色（既定は席ごとのページ色）。右クリックで選び直す"
                    : "空きセルの色（設定 → ROTO で変える）")
            .contextMenu {
                if hasMapping {
                    colorPickerMenu(cc: cc)
                }
            }
    }

    /// コンテキストメニューのパレット。**縦＝明度 / 横＝色相**の格子で出す —
    /// 設定画面と同じ並びなので、目が迷わない
    @ViewBuilder
    private func colorPickerMenu(cc: Int) -> some View {
        ForEach(Array(Roto.Color.matrix().enumerated()), id: \.offset) { _, matrixRow in
            // SwiftUI の contextMenu は横並びを持てないので、1 行ずつ Menu に畳む
            Menu(hueRowLabel(matrixRow)) {
                ForEach(Array(matrixRow.enumerated()), id: \.offset) { _, index in
                    if let index {
                        Button {
                            setCellColor?(cc, index)
                        } label: {
                            Label(
                                colorLabel(index),
                                systemImage: cellColor?(cc) == index
                                    ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                }
            }
        }
        Divider()
        // 戻す先は**この席の**ページ色（席ごとに色相をずらしてある）
        Button("この席のページ色に戻す") { setCellColor?(cc, nil) }
    }

    /// 格子 1 行の見出し（その行の明るさで示す）
    private func hueRowLabel(_ row: [UInt8?]) -> String {
        let lightness = row.compactMap { $0 }.map { Roto.Color.oklch($0).lightness }
        guard !lightness.isEmpty else { return "—" }
        let average = lightness.reduce(0, +) / Double(lightness.count)
        return String(format: "明度 %.2f", average)
    }

    /// 色 1 つの名前（index と RGB）
    private func colorLabel(_ index: UInt8) -> String {
        String(format: "#%d  %06X", index, Roto.Color.palette[Int(index)])
    }

    private func rowLabel(_ row: AssignList.Row) -> String {
        if row.reserved {
            return row.cc == 64 ? "サスティン（楽器へ素通し）" : "VALUE エンコーダー"
        }
        if let name = row.name { return name }
        // **演奏席の空きは「何も起きない」ではない**（mako 2026-08-05）。
        // 割当が無ければ CC はそのまま楽器へ流れる — ノブ席の空きとは意味が違う。
        // ⚠️ 楽器が受けるかまでは分からない（AU のパラメータツリーに MIDI CC の
        // 受け口は出てこない）。ModWheel を持たない音源では何も起きない
        if row.position == nil, let cc = row.cc,
            FaceKnobAssignment.controllerName(cc) != nil
        {
            return "楽器へ素通し"
        }
        return "（空き）"
    }

    private func rowColor(_ row: AssignList.Row) -> Color {
        if row.reserved { return theme.textTertiary.opacity(0.6) }
        if row.name == nil { return theme.textTertiary.opacity(0.5) }
        return theme.textPrimary
    }

    /// 現在値。⚠️ **`param.string(fromValue:)` は使わない** — AUv2 ブリッジ経由で
    /// プラグイン本体に問い合わせに行き、KORG のプラグイン内で落ちた
    /// （実機クラッシュ 2026-08-02。一覧は数十行を毎描画なぞるので踏みやすい）。
    /// 値と単位から自前で組む
    private func valueText(_ address: UInt64) -> String? {
        guard let param = slot.parameter(at: address) else { return nil }
        return ParameterFormat.text(value: param.value, unit: param.unit)
    }

    private func label(for cc: Int) -> String {
        if case .lpd8(let ccs) = surface, let index = ccs.firstIndex(of: cc) {
            return "K\(index + 1)"
        }
        return FaceKnobAssignment.ctrlLabel(cc)
    }

    private func rowHelp(_ row: AssignList.Row) -> String {
        guard let cc = row.cc else { return row.name ?? "" }
        if row.reserved {
            return cc == 64
                ? "CC64 — サスティンペダル（楽器へ素通し。キープもここで受ける）"
                : "CC\(cc) — VALUE エンコーダー予約"
        }
        let base = cc == FaceKnobAssignment.pitchBendControl
            ? "ピッチベンドホイール" : "\(label(for: cc)) (CC\(cc))"
        guard let name = row.name else { return "\(base) — 空き" }
        // 別名が付いていれば実名も併記する（何を鳴らしているか見失わないため）
        let alias = row.alias.map { _ in "（別名）" } ?? ""
        return "\(base) — \(name)\(alias)  押すと一覧から選び直せる"
    }

    // MARK: - 操作


}
