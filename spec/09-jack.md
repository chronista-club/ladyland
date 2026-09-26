# spec/09 — Jack(機材と Track の間の「使い方」レイヤー)

**ステータス**: v1 実装中(2026-08-25 起工)
**設計書**: [design/08-jack-layer.md](../design/08-jack-layer.md)

## What — Jack とは

**Jack = 機材と engine/Track の間に立つ「使い方」の差込口**(mako 発案 2026-08-25
「audio の engine/track と MIDI 機材の間に使い方レイヤーを入れれば、似たような
機材も吸収できる」、命名裁定「Jack はいいね。腑に落ちる」)。

Jack は 2 つの面を持つ:

1. **契約(Interface/Trait 的な面)** — 機材に要求する能力。
   「シンセ入力 Jack は Note On/Off + ベロシティを要求」
   「MIXER Jack は連続値ノブ × N を要求」。
   **要求を満たす機材セクションなら何でも刺せる** — これが「似た機材の吸収」
2. **束縛** — その Jack が engine 側のどこを指すか。
   シンセ入力 Jack は**担当 Track**(nil = カーソル追従)、
   サンプラ打面 Jack は drums、MIXER Jack は全体

操作の語彙は **刺す / 抜く**(スタジオのパッチベイの画)。

## Why

- **機材の吸収**: 機材が増えても・壊れても、Jack は不変で刺し替えるだけ(fail-open)
- **「担当」の整理**: 「機材が Track を持つ」のではなく
  **「シンセ入力 Jack が担当 Track を持ち、機材はそこに刺さる」** —
  Keystage = A Track / MiniLab = B Track が、機材ではなく Jack の属性になる
- **配役シーンの土台**: 接続表 + 束縛のスナップショット = 曲ごとの配役(将来)

## Jack の種類(v1 時点)

| Jack | 要求する能力 | 束縛 | 現状の実体(読み替え) |
|---|---|---|---|
| **シンセ入力 1** | 鍵盤(Note + vel) | 担当 Track(nil=追従) | keyboard 経路(Keystage / PC-KB / **Keystage 不在時の汎用鍵盤**) |
| **シンセ入力 2** | 鍵盤 | 担当 Track(nil=追従) | secondKeyboard 経路(MiniLab / NCXse / **Keystage 在席時の汎用鍵盤**) |
| **顔つまみ** | 連続値ノブ × 8 | 選択 Track(現ページの席 8) | Keystage のノブ帯 / **LPD8 ノブ 8(`Lpd8KnobJack.face`)** / ROTO SMART |
| **サンプラ打面** | パッド(Note + vel) | drums 固定 | drums 経路(LPD8) |
| MIXER(v2) | 連続値ノブ × N | 全 Track の gain | ROTO MIXER 冊(焼き)/ MiniLab ノブ 16(未配線) |
| ナビ/選択(整理のみ) | 相対エンコーダー/ボタン | カーソル | VALUE エンコーダー / RK / REW-FF |

## 決めたこと

- **粒度はセクション**(機材全体ではない): MiniLab の鍵盤 / ノブ 16 / パッド 16 は
  別々の Jack に刺せる
- **v1 の刺し替えは設営時のみ**(曲中の動的刺し替えは将来)
- 移行は**漸進**: 既存経路(keyboard/secondKeyboard/drums)は Jack の実体として
  そのまま生きる。接続表のデータ化(パッチベイ)は v2 以降
- **未知の鍵盤は捨てない**(mako 裁定 2026-09-26「スタジオにある MIDI 鍵盤を
  Keystage の代わりに」— 鍵盤の持ち運びが大変。PC + 小さな機材で動けるように):
  名前の分からない source は Keystage 不在ならシンセ入力 1、居ればシンセ入力 2 に
  **自動で刺さる**(設定なし)。ROTO / IAC / Network は鍵盤ではないので繋がない
- **LPD8 のノブ 8 は Jack で刺し替える**(drums / 顔つまみ。同日裁定)。顔つまみの
  ときは位置 i → 現ページ(`activeKnobPage ?? rotoPage`)の席 i。ページを LPD8 の
  PROG 番号で分ける案は不採用 — PROG はパッド用のまま、ページは ROTO / GUI に追従
