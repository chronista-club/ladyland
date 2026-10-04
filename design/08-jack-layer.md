# design/08 — Jack レイヤーの実装(3 層モデル)

**仕様**: [spec/09-jack.md](../spec/09-jack.md)
**ステータス**: v1 実装中(2026-08-25)

## 1. 3 層

```
機材層     Keystage(鍵盤+ノブ8) MiniLab(鍵盤+ノブ16+パッド16) LPD8 ROTO NCXse PC-KB
             ↓ 接続(機材セクション → Jack。v1 はコード内の対応、v2 でデータ化)
Jack 層    シンセ入力1 シンセ入力2 サンプラ打面 [MIXER] [ナビ]
             ↓ 束縛(担当 Track / drums / 全体)
engine 層  64 スロット / drums / master
```

## 2. v1 実装 = 「シンセ入力 1 に担当を持たせる」

鍵盤 2(`secondKeyboardSlot: Int?`、nil=追従/固定)と**同型のものを keyboard
経路に導入**する。これで「Keystage = A Track、MiniLab = B Track」が成立:

- `AppState.synthInput1Slot: Int?`(nil = カーソル追従 = 従来挙動)
- `updateRouting()` の keyboardTarget 解決を `synthInput1Slot ?? rack.selected` に
- UI: タイル右クリックに「シンセ入力 1(Keystage)をこの席に固定」を追加、
  バッジは既存「鍵2」と並べて「鍵1」
- 永続化: snapshot + DB 列(v10-jack-synth1)
- ⚠️ Keystage の**ノブ帯(顔つまみ)の主語は当面「選択」のまま**
  (Track 面の編集対象と一致させておく — 変えるかは運用の感触で裁定)

## 3. 既存コードと Jack の対応(読み替え表)

| コード上の実体 | Jack 語彙 |
|---|---|
| keyboardPort / keyboardTarget | シンセ入力 1 の実体 |
| secondKeyboardPort / secondKeyboardTarget | シンセ入力 2 の実体 |
| drumsPort / drumsTarget | サンプラ打面の実体 |
| `MIDIInput.route(forSourceName:hasKeystage:)` / `plan(sourceNames:)` | 接続表(純関数。未知の名前 → 汎用鍵盤) |
| `MIDIRouter.KeyboardOrigin`(keystage / generic) | keyboard 経路の**出どころの印** — 帳簿(latch / 和音)は共有、Keystage 専用の解釈(帯の飲み込み / PC ナビ / 焼きボタン / ch16)は keystage だけ。generic は鍵盤 2 と同じ通行証 + CC120 |
| `Lpd8KnobJack`(drums / face)+ `Lpd8FaceKnobs` | LPD8 ノブ 8 の刺し先。face は 4 プログラム分の CC を全部飲み、位置 → 現ページの席 → `faceKnobs`。snapshot `lpd8Knobs jack=` / DB `lpd8KnobJack`(v12) |
| `secondKeyboardSlot` / `synthInput1Slot` | 各シンセ入力 Jack の束縛 |

## 4. 段階

1. **v1**: synthInput1Slot + UI + 永続化 — モデルの本丸、既存挙動は nil で不変
1e. **3D の机(2026-10-04)**: RealityKit(`Desk3DView`、macOS 15 へ引き上げ)。
    `Gear3D.swift`(純関数)— `GearBlueprint`(実寸 mm の下書き。可動部は名前付き部品
    `fader_1` 等)、`VirtualComponent.canDock`(Jack の契約)、`DockModel`(落とした点 →
    セクション、載せ替え)、`SurfaceMapping`(実機の CC → 載せた部品の操作)。
    載せ先は window.json の `docks`。清書は Blender → `~/Library/Application Support/
    ladyland/gear/<id>.usdz` に置けば下書きの代わりに読む(部品は同じ名前で掴む)。
    nanoKONTROL2 の模型は `ladyland/Gear/nanokontrol.py`(Blender スクリプト。Blender
    MCP からも流せる)で組んで書き出す。USDZ では部品名が入れ物(Xform)と形(Mesh)の
    2 段になるので、材質を替えるときは子の形まで辿る(`Desk3DScene.model(of:)`)
1d. **結線図を机に畳む(2026-10-04)**: `DeskGraph`(純関数)が結線図の行 →
    ソケット(板 or 棚)、ケーブルの行き先(`CableTarget`)、プラグの札、
    落とした場所 → 刺し替え(`DeskRebind`)、LPD8 ノブに重ねる割当名を持つ。
    `MixerView(includeDrums:)` がストリップのアンカー(`DeskAnchorKey`)を出し、
    机はそこへケーブルを描く。⚠️ 板は傾けない — `rotation3DEffect` の遠近は
    当たり判定が元の位置に残る(実機 2026-10-01)。遠近は床と縮尺で出す
1c. **机 = 2.5D の Jack(2026-10-01、mako 赤入れ)**: Jack 面の広い版に、結線図の
    下として机を置く。`Desk.swift`(配置モデル、0-1 の机座標、window.json の
    `desk`)+ `DeskView`(`rotation3DEffect` の板に既存部品を乗せる)。操作は
    実機と同じ入口(`routeKeyboard` / `routeDrums`)。RealityKit への置き換えは
    配置モデルを残したまま描画だけ差し替える前提
1b. **汎用鍵盤 + LPD8 顔つまみ(2026-09-26)**: 接続表を純関数に切り出し、未知の
    鍵盤を自動で刺す。LPD8 ノブ 8 を「顔つまみ」Jack に刺し替えられる(Jack 面の
    LPD8 ノブ行の切替)。Jack 面の行は機材のセクション単位(Keystage 鍵盤 / ノブ 8、
    LPD8 パッド / ノブ 8)になり、汎用鍵盤は名前で行が生える
2. v2: MiniLab ノブ 16 → MIXER Jack(新経路 — gain の手元操作、ROTO MIXER 冊の対)
3. v3: 接続表のデータ化 + パッチベイ UI(機材セクション × Jack のマトリクス)
4. v4: 配役シーン(接続 + 束縛のスナップショット保存/呼出 — Page 既定と同じ文法)
