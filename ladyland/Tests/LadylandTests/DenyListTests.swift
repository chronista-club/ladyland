//! ホスティング deny list のテスト。
//!
//! Splice Sounds は AU Instrument を自称するサンプルブラウザで、
//! ホストすると null mutex SIGSEGV でアプリごと落ちる
//! （cortex 時代の実機クラッシュ。design/06 §5-1）。
//! 候補一覧に漏れないことをここで固定する。

import Testing

@testable import Ladyland

@Suite("deny list")
struct DenyListTests {
    @Test("Splice 系は弾く", arguments: ["Splice Sounds", "Splice Sounds Listener", "Splice Bridge"])
    func deniesSplice(name: String) {
        #expect(isDenyListed(name))
    }

    @Test("本番で使う楽器は通す",
          arguments: [
            "Serum 2",
            "Memphis (MS-20)",
            "London (Drum)",
            "Helsinki (Pad)",
            "Darwin (M1)",
          ])
    func allowsInstruments(name: String) {
        #expect(!isDenyListed(name))
    }

    @Test("カタログに deny 対象が漏れない（実機スキャン）")
    func catalogExcludesDenyListed() {
        // 実機の AU 構成に依存するが、「漏れない」ことは常に成り立つべき
        for component in PluginCatalog.instruments() {
            #expect(!isDenyListed(component.name), "deny 対象が候補に漏れた: \(component.name)")
        }
    }
}
