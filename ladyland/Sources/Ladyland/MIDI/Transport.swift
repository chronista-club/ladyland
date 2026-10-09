//! トランスポートの読み替え（design/09。mako 裁定 2026-10-09「Aで進めよう」）。
//!
//! X-Touch と nanoKONTROL2 には同じ並びの 5 つ（<< / >> / STOP / PLAY / REC）が
//! 付いている。届き方だけが違う — X-Touch は Mackie Control の Note、nano は CC。
//! ここで機材に依存しない `TransportAction` に読み替えてから 1 本の口
//! （`AppState.transport(_:)`）へ流す。**番号を書くのはこのファイルだけ**。
//!
//! 押下だけ拾い、解放は捨てる（両方通すと 1 押しで 2 回動く）。

/// 機材に依存しないトランスポートの操作
enum TransportAction: Equatable, Sendable {
    case rewind, fastForward, stop, play, record
}

enum Transport {
    /// nanoKONTROL2 の右下（既定の CC。KORG の工場出荷値）
    private static let nanoKontrol2: [UInt8: TransportAction] = [
        43: .rewind, 44: .fastForward, 42: .stop, 41: .play, 45: .record,
    ]

    /// X-Touch（Mackie Control）のトランスポート Note
    private static let mackie: [UInt8: TransportAction] = [
        0x5B: .rewind, 0x5C: .fastForward, 0x5D: .stop, 0x5E: .play, 0x5F: .record,
    ]

    /// nanoKONTROL2 の CC を読み替える（押下 = value > 0 だけ）
    static func action(nanoKontrolCC cc: UInt8, value: UInt8) -> TransportAction? {
        guard value > 0 else { return nil }
        return nanoKontrol2[cc]
    }

    /// Mackie Control の Note を読み替える（押下 = velocity > 0 だけ）
    static func action(mackieNote note: UInt8, velocity: UInt8) -> TransportAction? {
        guard velocity > 0 else { return nil }
        return mackie[note]
    }
}
