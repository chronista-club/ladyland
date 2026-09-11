/// ROTO のページ番号とセル番号の変換。
///
/// ページ状態や MIDI 送信は持たず、デバイスの座標を Ladyland の
/// コントロール番号へ写す規則だけを置く。
/// 実測の経緯: docs/roto-control/refactor-invariants.md「ページ座標」。
enum RotoPageLayout {
    /// SMART 面のページ割りは Keystage と同じ正典（ページ = CC / 8）。
    /// 2026-08-08 監査 B-1/B-9・08-09 実測: assignableCCs を8個ずつに
    /// 切るとP1からCC0/7が抜けCC8/9が混ざった。席プールで再分割しない。
    static let smartPages: [[Int]] = KnobPages.pages
    static let smartPageCount = smartPages.count

    /// SMART ページ番号を実在する範囲へ収める。
    static func clampedSmartPage(_ page: Int) -> Int {
        max(0, min(smartPageCount - 1, page))
    }

    /// SMART 面の物理ノブ位置を、指定ページのコントロール番号へ写す。
    static func smartCell(page: Int, knob: Int) -> Int? {
        guard smartPages.indices.contains(page) else { return nil }
        let cells = smartPages[page]
        guard cells.indices.contains(knob) else { return nil }
        return cells[knob]
    }

    /// デバイスが名乗る 16 セルを、現在ページの 8 コントロールへ写す。
    ///
    /// ROTO は前半 0...7 を表示しながら後半 8...15 で入力を返すことが
    /// あるため、前半と後半には同じページを重ねる。
    /// 2026-08-04: 0...7=P1 / 8...15=P2 を試すと、LCDはP1なのにP2が
    /// 動いた。16セルを2ページとして使わず、ページはホスト側で管理する。
    static func smartCell(page: Int, deviceCell: Int) -> Int? {
        guard (0..<RotoParam.smartCells).contains(deviceCell) else { return nil }
        return smartCell(page: page, knob: deviceCell % RotoParam.physicalKnobs)
    }

    /// PLUGIN 面のページ内ノブ位置を絶対セル番号へ写す。
    static func pluginCell(page: Int, knob: Int) -> Int {
        page * RotoParam.physicalKnobs + knob
    }
}
