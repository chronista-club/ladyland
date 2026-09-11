//! Keystage ノブ → 選択中楽器の「顔つまみ」（design/06 §3・§7、P4 本丸）。
//!
//! 物理楽器なみシンプル原則: 楽器 1 つにつき触るのは 2〜4 個の顔つまみ。
//! Keystage のノブ CC は鍵盤と同じ KBD/CTRL ポートに届き、CC 番号は
//! 位置で固定（ページ = CC ÷ 8 が正典。P1 = CC0-7。`KeystageKnobs`）。
//! ノブ帯（CC0-63）は**割当の有無に関わらず全部飲む** — 未割当ノブを
//! 回しても楽器には届かない。Mod ホイールは CC116 へ焼いて帯の外に居るので
//! そのまま楽器へ通る（かつては CC1 = ノブ2 と同番号で、「割当のある CC
//! だけ横取り」により素通しをユーザー選択に倒していた）。
//!
//! ピックアップ: Keystage ノブは終点ありポット（モーターなし）。
//! スロット切替直後は物理ノブ位置とパラメータ現在値が一般に食い違うため、
//! そのまま適用すると値が跳ぶ。ノブが現在値を「拾う」（十分近づく or
//! 跨ぐ）までは適用しない（cortex から持ち越した設計資産。design/06 §5-4）。

import AVFoundation
import KeystageKit

/// ノブ 1 本 → AU パラメータ 1 個の割当
struct FaceKnobMapping: Codable, Equatable {
    /// ノブ位置 0-7（= ページ1 の CC 番号と一致）
    var knob: Int

    /// AUParameterTree 上のアドレス（fullState と同時保存なので同一 AU 内で安定）
    var address: UInt64

    /// 表示・診断用のパラメータ名（アドレスが引けなくなったときの手掛かり）
    var name: String

    /// 手で付けた別名（design/06 §8 追補、2026-08-03）。
    ///
    /// **なぜ要るか**: AU が実名を出してくれないプラグインがある。実測で
    /// KORG Fairbanks は 16 個中 12 個が `Edit 1-8` / `Mod Fx Edit 1` のような
    /// 位置スロット名で、GUI 上の意味（Filter Cutoff 等）はプログラム依存
    /// （`swift run RigBench au-params Fairbanks`）。ROTO の LCD は 12 字なので
    /// 「Edit 1」と出たらライブでは使い物にならない。**人が名付けた名前が要る**。
    ///
    /// nil / 空文字 = 別名なし（AU の実名を使う）
    var alias: String?

    /// **パラメータの色**（ROTO 83 色 index。mako 要望 2026-08-15「パラメータ毎の
    /// カラーも設定できるようにしたい。Option 型で」）。
    ///
    /// 席（CC）ではなく**割当（パラメータ）の属性** — 配置換え・ページ入替・
    /// Page 既定の保存/ロードで色がパラメータについて回る。nil = 未設定で、
    /// 従来の優先順（席色 trackCells > トラックカラー > ページ色）に落ちる
    var color: UInt8?

    init(
        knob: Int, address: UInt64, name: String, alias: String? = nil,
        color: UInt8? = nil
    ) {
        self.knob = knob
        self.address = address
        self.name = name
        self.alias = alias
        self.color = color
    }
}

/// ダンパーペダルの役割（mako 裁定 2026-08-03）。
///
/// **なぜ切り替えるのか**: ペダルは 1 本しかないのに用途が 2 つある。
/// 「両手を空けるためのキープ」と「足で音色を動かす表情付け」は同時に成立
/// しないので、曲ごとにどちらで使うかを選ぶ。
enum PedalMode: String, Codable, CaseIterable {
    /// キープ（既存）— 踏んでいる間ノートを保持し、CC64 は楽器へも素通し。
    /// マトリクスでは CC64 は予約（割当不可）
    case keep

    /// 割当（新）— CC64 をマトリクスの一級市民にして顔つまみに割り当てる。
    /// キープはしない。未割当なら従来どおり楽器へ素通し（ネイティブ sustain）
    case assign

    var label: String {
        switch self {
        case .keep: return "キープ（ノート保持）"
        case .assign: return "割当（パラメータを動かす）"
        }
    }
}

/// 表示名の解決 — 純関数（テスト対象）。
/// **別名 > AU の現在名 > 割当時に控えた名前** の優先順で、最初に見つかった
/// 非空の名前を使う。AU が差し替わって実名が引けなくなっても手掛かりが残る
enum KnobLabel {
    static func resolve(alias: String?, live: String?, remembered: String?) -> String? {
        for candidate in [alias, live, remembered] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return nil
    }
}

/// 割当の編集 — 純関数（テスト対象）。パラメータ起点フロー（mako 裁定
/// 2026-08-01「プラグインが提供するリストに対して、それぞれに MIDI Ctrl を
/// 割り当てる」）の競合解消規則をここで固定する:
/// **1 ノブ 1 パラメータ / 1 パラメータ 1 ノブ**（両方向とも新しい割当が勝つ）
///
/// MIDI Ctrl は Keystage の 8 ノブ × 16 ページ = CC 0-127 のマトリクス
/// （docs/keystage §4: ページ p のノブ k = CC (p-1)×8+(k-1)。CC は位置固定）
enum FaceKnobAssignment {
    /// ダンパーペダル（Keystage の DAMPER ジャック）の CC 番号。
    /// 実機確認 2026-08-02: EXPRESSION ジャックは MIDI を出さず、DAMPER に
    /// 挿すと CC64 が流れる
    static let damperCC = 64

    /// **常に席から外す CC**（EXIT のみ。実測 2026-08-05）。
    ///
    /// Mod (CC116) / Exp (CC115) は予約**しない** — マトリクスの一級市民で、
    /// 手で割り当てられる（解除すれば楽器へ素通し。⚠️ 自動割振には配らない —
    /// mako 裁定 2026-08-09「Mod は自動では配らない」、`fillingDefaults`）。
    ///
    /// - `120` = EXIT ボタン。⚠️ **MIDI 仕様では All Sound Off** なので、
    ///   席にしていなくても押すたびに外の音源へ「全部止めろ」が飛ぶ
    ///   （CoreMIDI に排他制御は無い）。だから**ボタンの移設先にも選べない**
    /// - 焼いた操作子（ボタン = `Keystage.ladylandButtonCCs` の 102-110、
    ///   エンコーダー = 117/118）は `burnedControlCCs` が別枠で席から外す。
    ///   ボタンは**押下 127・解放 0 しか送らない**ので、割当があると
    ///   押した瞬間にパラメータが最大へ飛ぶ。
    ///   かつては 96-101 / 121-123（MIDI 予約番号の領域）に焼いていたが、
    ///   帯が CC0-63 の 8 ページに広がったのに合わせて 102-110（空き帯）へ
    ///   移した（それ以前は CC41-49 / 58-59 という実用領域のど真ん中を
    ///   潰していた）
    ///
    /// ⚠️ **ノブは移せない** — Keystage のノブは CC 番号フィールドを持たず、
    /// 「ページ p のノブ k = CC (p-1)×8+(k-1)」で位置固定
    /// （docs/keystage/README.md §4）。動かせるのはボタンだけ
    /// ⚠️ **CC62/63 は 2026-08-07 に解放した。** 「Track Up / Down →
    /// ROTO のページ送り」に充てていたが、**ページ送りは Rec/Loop
    /// （`ladylandButtonCCs` の 104/105）へ移った**ので理由が消えた。
    ///
    /// ⭐ しかも **Keystage のノブ帯（CC0-63）の一部**になったので、
    /// 予約したままだと **P8 の 7・8 番目が「回しても割り当てられない席」**
    /// になる。⚠️ **役目を終えた予約を残すと、こういう死角ができる**
    static let alwaysReservedCCs: Set<Int> = [120]

    /// ペダルモードに応じた予約 CC（mako 裁定 2026-08-03「ペダルを繋いだので
    /// 既存機能と切り替えながらプラグインにも流す道が欲しい」）。
    /// keep のときだけ CC64 を予約する — 割当に使うなら一級市民になる
    static func reservedCCs(pedal: PedalMode) -> Set<Int> {
        pedal == .keep ? alwaysReservedCCs.union([damperCC]) : alwaysReservedCCs
    }

    /// 互換のための既定（keep モード）。呼び手が増えたら pedal 版へ寄せる
    static let reservedCCs: Set<Int> = reservedCCs(pedal: .keep)

    /// ピッチベンドホイールの擬似 Ctrl 番号（CC ではないため 0-127 の外。
    /// 割当があればパラメータを駆動、未割当ならネイティブのベンドが楽器へ）
    static let pitchBendControl = 128

    /// **物理コントローラが固定で繋がっている席**（Keystage）。
    /// 自動で割り当てて別枠にまとめる — パラメータのリストには並べない。
    /// ここを普通の席に混ぜていたせいで、ROTO のノブが Pitch Bend を
    /// 回して音が出なくなる事故が起きた（2026-08-04）
    /// Mod ホイールの CC（**実機で焼いた値**）。
    ///
    /// ## 経緯 — 2 回動いている
    ///
    /// | 日付 | 値 | なぜ |
    /// |---|---|---|
    /// | 〜2026-08-05 | **CC1**（ネイティブ） | ⚠️ **物理ノブ 2 と同番号**だった |
    /// | 2026-08-05 | **CC119** | mako「Wheel を CC119 にした」 |
    /// | 2026-08-07 | **CC116** | mako「ModWheel CC116 にしよう」 |
    ///
    /// ⚠️ **CC1 を離れた理由を消すな** — ネイティブのままだと**物理ノブ 2 が
    /// CC1 固定で送る**ので、ホイールとノブが同じ番号を送って区別が付かなかった。
    /// 119 へ焼いた時点で **CC1 が席に戻り**、ノブ 2 が P1 の一員になった。
    /// ⭐ **モジュレーションをネイティブで捨てる判断はそこで済んでいる**ので、
    /// 116 へ動かしても新たな代償は無い。
    ///
    /// ⚠️ 実装チャートの Wheel 欄（53-55）には MIDI Ch / Lower / Upper しか
    /// 無く「CC 番号は変えられない」と読んだが、**実機では変えられた**。
    /// チャートの記載が不完全か、別の場所に CC 番号がある。
    ///
    /// ⚠️ **111-116 は空き帯**（`KeystageProtocol.ladylandButtonCCs` の doc）。
    /// ノブ帯（`KeystageKnobs`）・ボタン（102-110）・エンコーダー（117/118）の
    /// どれとも重ならない — `modWheelDoesNotCollide` が固定している
    static let modWheelCC = 116

    /// Expression ペダルの CC の**予約席**（115。実機はここに居ない — 下記）。
    ///
    /// ⚠️ **「EXPRESSION ジャック無反応」（2026-08-07 実測）は誤りだった** —
    /// 2026-08-16、ペダルを踏むと**ネイティブの CC11 が届く**ことを実機で確認
    /// （当時の「115 へ焼いた」は Dump 上の確認で、送出の実証はできていなかった。
    /// 実機の Pedal 2 は Exp. Pedal モードのまま = CC11 送出）。
    ///
    /// **mako 裁定 2026-08-16「CC11（と CC64）はそのままにしとこうかな」** —
    /// KONTROL EDITOR で CC へ置き換える口（Pedal 2 Mode=CC）は確認済みだが
    /// 使わない。CC11 は帯の中（P2 の 4 番目）なので、帰結として
    /// **「どの楽器でも P2-4 の席はペダルでも踏める」が仕様**になる。
    /// ⚠️ CC# を手で振り直すときは 102-110（ボタン焼き帯）を避けること —
    /// 踏むたびにボタン扱いで誤発火する。安全なのは 111-116 の空き帯。
    ///
    /// この 115 は「振り直すならここ」という予約のまま残す（誰も送っていない）
    static let expressionCC = 115

    static let controllerCCs: [Int] = [
        modWheelCC, expressionCC, damperCC, pitchBendControl,
    ]

    /// **MIDI 仕様上の危険牌**（分類の記録）。かつては席プールの並びで
    /// **後ろのページへ回して**いたが、席が帯そのもの（CC0-63 = 番号順、
    /// 2026-08-09）になってからは並びに効かない — 帯は全部飲むので、
    /// ladyland の楽器にはそもそも届かない（外の音源には届く。末尾参照）。
    ///
    /// - `120-127` = Channel Mode Messages。120 = All Sound Off /
    ///   121 = Reset All Controllers / 123 = All Notes Off を含む。
    ///   **ノブを回した瞬間に音が全部切れる**（ladyland の panic と同じ命令）
    /// - `96-101` = Data Inc/Dec と NRPN / RPN のパラメータ選択。
    ///   「次に来る値が何を指すか」を決める CC なので、単独で動かすと
    ///   機器内部の別パラメータが書き換わる
    /// - `65-69` = ペダル類（Portamento / Sostenuto / Soft / Legato / Hold2）。
    ///   **スイッチとして解釈される**（値 64 以上で ON）ので、ノブを半分より
    ///   上に回すと張り付く。66 と 69 は**音が止まらなくなる**。
    ///   CC64 (Damper) だけ演奏席へ逃がしても、隣の 5 本が素通しでは片手落ち
    /// - `0` / `32` = Bank Select MSB/LSB、`7` = Channel Volume、`10` = Pan。
    ///   Bank Select は Program Change と組で音色を切り替える —
    ///   **Keystage の VALUE エンコーダーが PC を 0-127 で撒いている**ので
    ///   行き先が生きている（design/06 §8 の実測）
    ///
    /// **`6` / `38`（Data Entry）は含めない**。Data Entry は RPN/NRPN で
    /// アドレスを立てた後に初めて意味を持つ値で、**アドレス側（96-101）を
    /// 伏せてある以上、単独で回しても行き先が無い**。前に出しても実害がない
    ///
    /// 危険の実体は ladyland の内部ではなく **CoreMIDI の外側**にある。
    /// 排他制御が無いので Keystage のノブが送る CC は VP・Logic・他の音源へ
    /// 同時に届き、**隣で聞いている誰かが MIDI 仕様どおりに解釈してしまう**
    static let unsafeCCs: Set<Int> =
        Set(120...127)
        .union([96, 97, 98, 99, 100, 101])  // NRPN / RPN
        .union([65, 66, 67, 68, 69])  // ペダル類（スイッチ扱い）
        .union([0, 7, 10, 32])  // Bank Select / Volume / Pan

    /// パラメータへ振れる席 = **Keystage のノブ帯そのもの**（CC0-63、64 席。
    /// mako 裁定 2026-08-09「他の用途で使う時はあると思うけど、Page は 8 つで」）。
    ///
    /// ⭐ **ページの正典は 1 つ**: ページ = CC ÷ 8（`KeystageKnobs`）。
    ///
    /// かつては 0-127 から予約を除いた約 113 席を「危険牌を後ろへ」と並び替えて
    /// 8 個ずつに切っていた（「P15 まで担保」— 2026-08-04 の要望。当時ノブ帯は
    /// 無かった）。#75 で帯ができた後、その切り方は**帯と食い違う第 2 の
    /// ページ定義**として残り、ROTO の LCD だけがそれを映し続けた
    /// （監査 2026-08-08 の B-1、mako 実測 2026-08-09「LCD がズレてる」）。
    /// 帯の外（CC65+）は席にしない — 将来の別用途に空けてある。
    /// ⚠️⚠️ **ladyland が焼いた操作子の CC**（ボタン 102-110 / エンコーダー 117-118）。
    ///
    /// **席にしてはいけない**（監査 2026-08-08 の B-4）。ここに席が付くと、
    /// Gadget 系（数百パラメータ）で「全部割り当てる」を走らせたときに
    /// **ページ送り（Rec/Loop）やトラックナビ（REW/FF）へパラメータが載る**。
    ///
    /// ⚠️ **そうなると役割が消える**: `MIDIRouter` はノブの割当（`knobCCs`）を
    /// **横取り表より先に見る**ので、割当が付いた瞬間にボタンは
    /// 「ページを繰る操作子」ではなく「**パラメータを 127 へ飛ばすノブ**」になる。
    ///
    /// ⚠️ **番号を直書きしない** — `Keystage` の焼く値そのものから引く。
    /// 焼き先を移せば除外も付いてくる
    static let burnedControlCCs: Set<Int> = {
        let buttons: [Int] = Keystage.ladylandButtonCCs.map { Int($0.1) }
        let encoders: [Int] = Keystage.ladylandEncoderCCs.map { Int($0.1) }
        return Set(buttons).union(encoders)
    }()

    /// ⚠️ 操作子が帯の中へ引っ越してきたら自動で席から抜ける（filter が守る）。
    /// いまは taken が全部帯の外なので、実質 `KnobPages.all` と同じ 64 席
    static let assignableCCs: [Int] = {
        let taken = Set(controllerCCs).union(alwaysReservedCCs).union(burnedControlCCs)
        return KnobPages.all.filter { !taken.contains($0) }
    }()

    /// この席は危険牌か（UI で印を出す用）
    static func isUnsafe(cc: Int) -> Bool { unsafeCCs.contains(cc) }

    /// **演奏席の役割名**（mako 要望 2026-08-05「PB じゃなくて、Damper とか
    /// ModWheel とか分かりやすいので」「略さない方がいいな」）。ノブ席は nil。
    ///
    /// 一覧の座標欄は物理ノブの位置番号（1-8）を出すが、演奏席には位置が無い。
    /// そこを一律「PB」と書いていたので、Mod も Exp も Damper も PB に見えていた
    static func controllerName(_ cc: Int) -> String? {
        switch cc {
        case modWheelCC: return "ModWheel"
        case expressionCC: return "Expression"
        case damperCC: return "Damper"
        case pitchBendControl: return "Pitch Bend"
        default: return nil
        }
    }

    // `slotLabel(index:)` と `pages<T>(_:perPage:)` はここに居たが、2026-08-09 に
    // 削除した — 「リストの位置で切る」第 2 のページ定義の道具で、正典
    // （ページ = CC ÷ 8、`KeystageKnobs`）と食い違う答えを出す出口だった
    // （監査 2026-08-08 の B-1/B-8/B-10。最後の使い手は `RotoPageLayout.smartPages`）

    /// マトリクス座標の表示名（CC 24 → "P4-1"、128 → "PB"）
    static func ctrlLabel(_ cc: Int) -> String {
        cc == pitchBendControl ? "PB" : "P\(cc / 8 + 1)-\(cc % 8 + 1)"
    }

    /// 物理コントローラのバッジ（マトリクスのセルに重ねる小さな目印）
    static func controllerBadge(_ cc: Int) -> String? {
        switch cc {
        case modWheelCC: return "M"  // Mod ホイール（実機で焼いた値。CC1 ではない）
        case expressionCC: return "E"  // Expression ペダル
        case pitchBendControl: return "PB"
        default: return nil
        }
    }

    /// 受信 CC から Keystage ノブの現在ページを読む（0-based。nil = 材料外）。
    ///
    /// Page +/- ボタンは MIDI を送らない（Keystage_MIDIimp.txt 精査 2026-08-01:
    /// 割当可能ボタン一覧に無く、Parameter Change Push は BPM のみ、「現在ページ」は
    /// 機器内パラメータとして存在せず問い合わせも不可）ため、CC 番号 = 位置固定を
    /// 頼りに読む — 追従が遅れるのは最初のノブ 1 動きまでだけ。
    /// 誤追従の除外は「帯の外」そのもの（Mod 116 / Exp 115 / CC64 以降 /
    /// PB 128 — かつての除外リスト CC1/11/62-64 は演奏席の焼き替えで消えた）
    static func inferredPage(cc: Int) -> Int? {
        // ⭐ **CC 番号がページを自己申告する** — ページ = CC ÷ 8 が唯一の正典
        // （mako 裁定 2026-08-09「Page は 8 つで」）。帯の外は材料外。
        // かつてはここに「席プールの並びの位置から引く」第 2 の答えがあり、
        // 帯と食い違うページを返しうる出口になっていた（監査 B-1）
        KnobPages.page(forCC: cc)
    }

    /// ノブストリップの見出し（page は 0-based、nil = 未確定）。
    ///
    /// ⚠️⚠️ **帯（`KeystageKnobs`）から引く**（監査 2026-08-08 の B-2）。
    /// 見出しだけ**席プールの分割**を使っていたので、**中身と食い違っていた** —
    /// ノブ 1（CC0）を回すと、見出しには **CC0 も CC7 も無く CC8/9 がある**
    /// という状態だった（`KnobStrip.cells` は帯分割）。
    ///
    /// ⭐ **ここは Keystage のノブ HUD 専用**なので、帯が正しい源。
    /// 割当一覧（`AssignList`）の Keystage 側も `KnobPages.pages` を使う
    static func pageLabel(_ page: Int?) -> String {
        guard let page else { return "P?" }
        let seats = KnobPages.page(page)
        guard !seats.isEmpty else { return "P?" }
        return "P\(page + 1) · CC" + AssignList.compactRanges(seats)
    }
    /// パラメータへノブを割り当てる（既存の両方向競合は取り除く）。
    /// **別名はパラメータについて回る** — 同じパラメータを別のセルへ移しても
    /// 手で付けた名前は失わない（付け直しはライブ前の貴重な時間を溶かす）
    static func assigning(
        _ mappings: [FaceKnobMapping], knob: Int, address: UInt64, name: String
    ) -> [FaceKnobMapping] {
        let inheritedAlias = mappings.first { $0.address == address }?.alias
        var result = mappings.filter { $0.knob != knob && $0.address != address }
        result.append(
            FaceKnobMapping(knob: knob, address: address, name: name, alias: inheritedAlias))
        return result
    }

    /// セルに別名を付ける / 外す（空文字・空白のみ = 外す）
    static func aliasing(
        _ mappings: [FaceKnobMapping], knob: Int, alias: String?
    ) -> [FaceKnobMapping] {
        let trimmed = alias?.trimmingCharacters(in: .whitespaces)
        return mappings.map { mapping in
            guard mapping.knob == knob else { return mapping }
            var renamed = mapping
            renamed.alias = (trimmed?.isEmpty ?? true) ? nil : trimmed
            return renamed
        }
    }

    /// パラメータの割当を外す
    static func removing(_ mappings: [FaceKnobMapping], address: UInt64) -> [FaceKnobMapping] {
        mappings.filter { $0.address != address }
    }

    /// **席の移動 / 交換**（INST マトリクスのドラッグ。mako 要望 2026-08-12
    /// 「drag & drop で割り当て変更」）。移動先が埋まっていれば交換 —
    /// billboard のタイル交換と同じ「消えない」操作。空きへ落とせば移動
    static func swappingSeats(
        _ mappings: [FaceKnobMapping], _ a: Int, _ b: Int
    ) -> [FaceKnobMapping] {
        guard a != b else { return mappings }
        return mappings.map { mapping in
            var moved = mapping
            if mapping.knob == a {
                moved.knob = b
            } else if mapping.knob == b {
                moved.knob = a
            }
            return moved
        }
    }

    /// **ページの丸ごと交換**（P a ⇄ P b の 8 席。行ヘッダのドラッグ）
    static func swappingPages(
        _ mappings: [FaceKnobMapping], _ a: Int, _ b: Int
    ) -> [FaceKnobMapping] {
        guard a != b else { return mappings }
        return mappings.map { mapping in
            let page = mapping.knob / KnobPages.perPage
            let position = mapping.knob % KnobPages.perPage
            var moved = mapping
            if page == a {
                moved.knob = b * KnobPages.perPage + position
            } else if page == b {
                moved.knob = a * KnobPages.perPage + position
            }
            return moved
        }
    }

    /// **ページのコピー**（from の 8 席を to へ複製。to の既存は消える —
    /// 呼び手が 1 段の戻しを持つ）。同じパラメータが 2 ページに載る状態を
    /// 許容する（両ノブが同じパラメータを動かす。後から `assigning` で
    /// 載せ直せば「1 パラメータ 1 席」へ自然に解消される）。
    /// ⚠️ 同一スロット内のみ — address は AU 依存（mako 裁定 2026-08-12）
    static func copyingPage(
        _ mappings: [FaceKnobMapping], from: Int, to: Int
    ) -> [FaceKnobMapping] {
        guard from != to else { return mappings }
        var result = mappings.filter { $0.knob / KnobPages.perPage != to }
        for mapping in mappings where mapping.knob / KnobPages.perPage == from {
            var copied = mapping
            copied.knob = to * KnobPages.perPage + mapping.knob % KnobPages.perPage
            result.append(copied)
        }
        return result
    }

    /// **自動割振が避ける CC**（予約 + ⚠️ **焼いた操作子**）。
    ///
    /// ⚠️⚠️ **`burnedControlCCs` を足したのが 2026-08-08 の修正**（監査 B-4）。
    /// それまでは `reservedCCs`（= EXIT と Damper）しか避けておらず、
    /// Gadget 系（数百パラメータ）で全割当を走らせると
    /// **ページ送り（Rec/Loop）やトラックナビ（REW/FF）に席が付いた**。
    ///
    /// ⚠️ そうなると `MIDIRouter` がノブの割当を横取り表より先に見るので、
    /// **ボタンの役割が消えて「押すと 127 へ飛ぶノブ」になる**
    static func autoAssignAvoids(pedal: PedalMode = .keep) -> Set<Int> {
        reservedCCs(pedal: pedal).union(burnedControlCCs)
    }

    /// 未割当のパラメータを空きセルへ順に敷き詰める（mako 裁定 2026-08-01
    /// 「デフォルトで全パラメータ割り当てられてる」）。既存の割当は動かさない。
    ///
    /// ⭐ **席プール（= 帯、64 席）から配る**。かつては `0..<128` を歩いて
    /// **帯の外にまで席を作っていた** — ROTO からしか届かない席で、ページの
    /// 正典（8 ページ）の外に第 2 の世界が生えていた（監査 B-1。2026-08-09 に
    /// プールへ一本化）。席が尽きたら残りは未割当のまま
    /// （Gadget 系の数百パラメータ > 64 席）
    static func fillingDefaults(
        _ mappings: [FaceKnobMapping], parameters: [(address: UInt64, name: String)]
    ) -> [FaceKnobMapping] {
        let usedCCs = Set(mappings.map(\.knob))
        var assigned = Set(mappings.map(\.address))
        var result = mappings
        let avoid = autoAssignAvoids()
        // ⚠️ **配るのは席プール（= 帯）だけ**（mako 裁定 2026-08-09「Mod は
        // 自動では配らない」）。かつては溢れたぶんを Mod / Exp ホイールへ
        // 続けていた（8/5 の「全部割り当てたい」）が、64 席時代は**溢れたとき
        // だけ運任せのパラメータがホイールに載る**形になるのでやめた。
        // ホイールへの割当は演奏セクションから手で選ぶ
        var seats = assignableCCs.filter { !usedCCs.contains($0) && !avoid.contains($0) }[...]
        for parameter in parameters where !assigned.contains(parameter.address) {
            guard let cc = seats.first else { break }
            seats = seats.dropFirst()
            result.append(
                FaceKnobMapping(knob: cc, address: parameter.address, name: parameter.name))
            assigned.insert(parameter.address)
        }
        return result
    }

    /// **spec の配置を先に適用してから、残りを敷き詰める**
    /// （spec/06-gadget-knob-map.kdl。mako 要望 2026-08-04）。
    ///
    /// spec は「P1 に何を出すか」だけ決める設計なので、書かれていない
    /// パラメータは AU の並び順で後ろへ自動的に回る。
    /// **spec の指定セルは他の割当より優先**する — 既にそのセルを使っている
    /// 割当があれば、そちらを空きへ追い出す。
    /// - Parameter keeping: 既存の割当。**手で付けた別名だけを引き継ぐ**
    ///   （位置は spec が決め直す — 配置を揃えるのが spec の役目なので）
    static func applying(
        _ map: GadgetKnobMap, to parameters: [(address: UInt64, name: String)],
        keeping existing: [FaceKnobMapping] = []
    ) -> [FaceKnobMapping] {
        let wanted = map.byCell
        let byName = Dictionary(
            parameters.map { ($0.name, $0.address) }, uniquingKeysWith: { first, _ in first })
        // **別名はパラメータについて回る** — 位置が変わっても手で付けた名前は失わない
        let aliases = Dictionary(
            existing.compactMap { mapping in mapping.alias.map { (mapping.address, $0) } },
            uniquingKeysWith: { first, _ in first })

        var result: [FaceKnobMapping] = []
        var placed = Set<UInt64>()
        for (cell, name) in wanted.sorted(by: { $0.key < $1.key }) {
            // ⚠️ spec が焼いた操作子のセルを指していても置かない
            // （`fillingDefaults` と同じ規律。監査 2026-08-08 の B-4）
            guard !autoAssignAvoids().contains(cell), let address = byName[name] else { continue }
            result.append(
                FaceKnobMapping(
                    knob: cell, address: address, name: name, alias: aliases[address]))
            placed.insert(address)
        }
        // spec に無いものは AU の並び順で空きセルへ
        let rest = parameters.filter { !placed.contains($0.address) }
        return fillingDefaults(result, parameters: rest).map { mapping in
            guard mapping.alias == nil, let alias = aliases[mapping.address] else { return mapping }
            var kept = mapping
            kept.alias = alias
            return kept
        }
    }

    /// 指定セル列へ先頭から敷き詰める（LPD8 の K1-K8 など面が限られる機材用。
    /// パラメータがセルより多ければ溢れは未割当）
    static func fillingDefaults(
        onto ccs: [Int], parameters: [(address: UInt64, name: String)]
    ) -> [FaceKnobMapping] {
        zip(ccs, parameters).map { cc, parameter in
            FaceKnobMapping(knob: cc, address: parameter.address, name: parameter.name)
        }
    }

    /// セル 2 つの中身を入れ替える（空セルが相手なら移動。予約セルが絡むときは何もしない）。
    ///
    /// ⚠️ **いまは呼び出し側が無い**（2026-08-05）。割当 UI がドラッグ&ドロップから
    /// セレクト方式へ移り、重複時は `assigning` の**移動**に一本化した。
    /// 交換が要る操作を足すときはここを使う — ロジックとテストは生きている
    static func swapping(_ mappings: [FaceKnobMapping], _ a: Int, _ b: Int) -> [FaceKnobMapping] {
        guard a != b, !reservedCCs.contains(a), !reservedCCs.contains(b) else { return mappings }
        return mappings.map { mapping in
            var moved = mapping
            if mapping.knob == a { moved.knob = b }
            if mapping.knob == b { moved.knob = a }
            return moved
        }
    }
}

/// ピックアップ判定 — 純関数 state machine（テスト対象）
///
/// 値はすべて 0-1 正規化。engage までの条件:
/// - ノブ値がパラメータ現在値に十分近い（±0.02 ≒ CC 2.5/127）
/// - または前回のノブ値と今回のノブ値が現在値を跨いだ
/// 一度 engage したら reset まで素通し。
struct KnobPickup {
    static let nearThreshold = 0.02

    private var engaged: [Bool]
    private var lastValue: [Double?]

    init(knobCount: Int = 8) {
        engaged = Array(repeating: false, count: knobCount)
        lastValue = Array(repeating: nil, count: knobCount)
    }

    /// スロット切替・割当変更時に全ノブを disengage する
    mutating func reset() {
        for i in engaged.indices {
            engaged[i] = false
            lastValue[i] = nil
        }
    }

    /// engage 済みか（ノブストリップのゴースト針判定）
    func isEngaged(_ knob: Int) -> Bool {
        engaged.indices.contains(knob) && engaged[knob]
    }

    /// 最後に受けた物理ノブ位置 0-1（未受信は nil）
    func lastKnobValue(_ knob: Int) -> Double? {
        lastValue.indices.contains(knob) ? lastValue[knob] : nil
    }

    /// ノブ値を適用してよいか。value = ノブ値、target = パラメータ現在値（とも 0-1）
    mutating func accept(knob: Int, value: Double, target: Double) -> Bool {
        guard engaged.indices.contains(knob) else { return false }
        if engaged[knob] {
            lastValue[knob] = value
            return true
        }
        let previous = lastValue[knob]
        lastValue[knob] = value
        let near = abs(value - target) <= Self.nearThreshold
        // 前回値と今回値が target を挟んでいれば「通過した」
        let crossed = previous.map { ($0 - target) * (value - target) <= 0 } ?? false
        if near || crossed {
            engaged[knob] = true
            return true
        }
        return false
    }
}

/// 顔つまみの実行部 — CC 受信（main へホップ済み）→ ピックアップ → AU パラメータ適用
///
/// CC はノートほどレイテンシに敏感でないため、RT スレッドから MainActor へ
/// ホップしてから処理する（選択スロット・割当の観測が自然に整合する）。
@MainActor
final class FaceKnobController {
    // 8×16 ページのマトリクス割当（2026-08-01）で CC 0-127 全域 + PB (128) が対象
    private var pickup = KnobPickup(knobCount: 129)
    private weak var slot: InstrumentSlot?

    /// 送り先スロットを切り替える（選択切替・ロード・割当変更時）。
    /// ピックアップは必ず仕切り直す — 切替の段差吸収の要
    func focus(_ slot: InstrumentSlot?) {
        self.slot = slot
        pickup.reset()
    }

    /// ノブストリップ表示用のピックアップ状態（cc = Ctrl 番号）。
    /// knobValue = 最後に受けた物理ノブ位置 0-1 — 未キャッチのゴースト針に使う
    func pickupState(cc: Int) -> (engaged: Bool, knobValue: Double?) {
        (pickup.isEngaged(cc), pickup.lastKnobValue(cc))
    }

    /// ノブ CC を処理する（knob = CC 0-7、value127 = CC 値 0-127）
    func handle(knob: Int, value127: Int) {
        guard let slot,
              let mapping = slot.knobMappings.first(where: { $0.knob == knob }),
              let param = slot.parameter(at: mapping.address)
        else { return }

        let value = Double(value127) / 127.0
        let minValue = Double(param.minValue)
        let range = Double(param.maxValue) - minValue
        guard range > 0 else { return }
        let target = (Double(param.value) - minValue) / range

        guard pickup.accept(knob: knob, value: value, target: target) else { return }
        let newValue = AUValue(minValue + range * value)
        param.setValue(newValue, originator: nil)
    }
}
