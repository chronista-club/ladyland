import Foundation

struct XTouchAssignment: Identifiable {
    let id: String
    let control: String
    let action: String
    let notes: ClosedRange<UInt8>?
    let assigned: Bool
}

enum XTouchAssignments {
    static let all: [XTouchAssignment] = [
        .init(id: "solo", control: "SOLO ×8", action: "担当TrackのSoloを切替。複数選択でき、他のTrackとドラムを消音", notes: 0x08...0x0f, assigned: true),
        .init(id: "mute", control: "MUTE ×8", action: "担当TrackのMuteを切替。解除すると元の音量へ戻る", notes: 0x10...0x17, assigned: true),
        .init(id: "select", control: "SELECT ×8", action: "担当Trackを選択。選択に追従する演奏入力と編集対象を切替", notes: 0x18...0x1f, assigned: true),
        .init(id: "bank", control: "FADER BANK ◀ ▶", action: "64Track内を8Trackずつ移動", notes: 0x2e...0x2f, assigned: true),
        .init(id: "channel", control: "CHANNEL ◀ ▶", action: "64Track内を1Trackずつ移動", notes: 0x30...0x31, assigned: true),
        .init(id: "pan", control: "ノブ：回す", action: "担当TrackのPanを調整。LEDリングも追従", notes: nil, assigned: true),
        .init(id: "centerPan", control: "ノブ：押す", action: "Panを中央へ戻す", notes: 0x20...0x27, assigned: true),
        .init(id: "fader", control: "フェーダー ×8", action: "担当Trackの音量を調整。画面や保存値にモーターが追従", notes: nil, assigned: true),
        .init(id: "master", control: "MASTER", action: "ドラムを含む全体音量。Bankを移動しても担当は変わらない", notes: nil, assigned: true),
        .init(id: "touch", control: "フェーダータッチ", action: "触れている間はモーター送信を止め、Bank移動を保留", notes: nil, assigned: true),
        .init(id: "rec", control: "REC ×8", action: "役割は検討中。録音待機・録音開始はまだ行わない", notes: 0x00...0x07, assigned: false),
        .init(id: "transport", control: "Transport", action: "REW / FF / STOP / PLAY / REC", notes: nil, assigned: false),
        .init(id: "assign", control: "ASSIGN / F1–F8", action: "ノブの役割切替・機能キー", notes: nil, assigned: false),
        .init(id: "automation", control: "Automation / 修飾キー", action: "READ / WRITEなど・SHIFT / OPTIONなど", notes: nil, assigned: false),
        .init(id: "navigation", control: "カーソル / ジョグ", action: "ZOOM / SCRUBを含む移動操作", notes: nil, assigned: false),
    ]
}
