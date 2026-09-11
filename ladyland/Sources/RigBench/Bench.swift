//! ベンチの共通形（cargo bench の harness に相当する最小プロトコル）。
//!
//! 追加手順: Benches/ に 1 型作り、main.swift の `benches` 一覧に足すだけ。
//! 機材測定は criterion 的な統計反復ではなく「副作用あり・1 ショット・目視併用」の
//! システム測定なので、反復や統計は各ベンチが自分で持つ。

protocol Bench {
    /// CLI で指定する名前（kebab-case）
    var name: String { get }
    /// 一覧表示用の 1 行説明
    var summary: String { get }
    func run() throws
}
