# wave-generator アーキテクチャ設計

> REQ-CORE-001〜REQ-PRESET-001の設計詳細

## システムアーキテクチャ

```
┌─────────────────────────────────────────────────────────────────┐
│                        Main Thread                               │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐           │
│  │   winit     │──▶│  wgpu       │──▶│  Encoder    │──▶ MP4    │
│  │  EventLoop  │   │  Renderer   │   │  (video-rs) │           │
│  └─────────────┘   └─────────────┘   └─────────────┘           │
│         │                 ▲                                      │
│         │                 │                                      │
│         ▼                 │                                      │
│  ┌─────────────┐   ┌─────────────┐                              │
│  │    MIDI     │──▶│  Shader     │                              │
│  │  Controller │   │  Uniforms   │                              │
│  └─────────────┘   └─────────────┘                              │
│                           ▲                                      │
│                           │                                      │
│                    ┌─────────────┐                              │
│                    │  Analysis   │◀── Ring Buffer               │
│                    │    Data     │                              │
│                    └─────────────┘                              │
└─────────────────────────────────────────────────────────────────┘
                            ▲
                            │
┌───────────────────────────┴─────────────────────────────────────┐
│                       Audio Thread                               │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐           │
│  │  symphonia  │──▶│    cpal     │──▶│  Analyzer   │           │
│  │   Decoder   │   │   Output    │   │  (rustfft)  │           │
│  └─────────────┘   └─────────────┘   └─────────────┘           │
│                                              │                   │
│                                              ▼                   │
│                                       Ring Buffer               │
└─────────────────────────────────────────────────────────────────┘
```

---

## クレート構成

```
bikeboy-wave-generator/
├── Cargo.toml              # Workspace + Main binary
├── src/
│   └── main.rs             # アプリケーションエントリポイント
│
└── crates/
    ├── wave-core/          # 共有データ型
    │   └── src/
    │       ├── lib.rs
    │       ├── audio.rs    # AudioFrame, AnalysisData
    │       ├── shader.rs   # ShaderUniforms, EncoderConfig
    │       └── error.rs    # WaveError
    │
    ├── wave-audio/         # オーディオ処理
    │   └── src/
    │       ├── lib.rs
    │       ├── decoder.rs  # symphoniaラッパー
    │       ├── player.rs   # cpalラッパー
    │       ├── analyzer.rs # FFT/ビート検出
    │       └── ringbuffer.rs # スレッド間通信
    │
    ├── wave-visual/        # GPUレンダリング
    │   └── src/
    │       ├── lib.rs
    │       ├── renderer.rs # wgpuレンダラー
    │       ├── pipeline.rs # シェーダーパイプライン
    │       └── shader.rs   # 組み込みシェーダー
    │
    ├── wave-midi/          # MIDI入力
    │   └── src/
    │       ├── lib.rs
    │       ├── handler.rs  # midirラッパー
    │       └── controller.rs # パラメータマッピング
    │
    ├── wave-encoder/       # 動画エンコード
    │   └── src/
    │       └── lib.rs      # video-rsラッパー
    │
    └── wave-preset/        # プリセット管理
        └── src/
            └── lib.rs      # KDLパーサー
```

---

## データフロー

### オーディオ処理パイプライン

```
File → Decoder → AudioFrame → cpal → Speaker
                     │
                     ▼
                Ring Buffer
                     │
                     ▼
                Analyzer → AnalysisData → ShaderUniforms
```

### レンダリングパイプライン

```
ShaderUniforms → Uniform Buffer → Shader → Frame → Surface
                                              │
                                              ▼
                                    Capture Buffer → Encoder → MP4
```

---

## 主要データ構造

### ShaderUniforms (112 bytes)

```rust
#[repr(C)]
pub struct ShaderUniforms {
    // 時間・解像度 (16 bytes)
    time: f32,
    resolution: [f32; 2],
    delta_time: f32,

    // オーディオ解析 (16 bytes)
    rms: f32,
    bass: f32,
    mid: f32,
    high: f32,

    // ビート情報 (16 bytes)
    beat_intensity: f32,
    beat_count: f32,
    beat_interval: f32,
    time_since_beat: f32,

    // MIDI CC (32 bytes)
    midi_cc: [f32; 8],

    // MIDI追加情報 (16 bytes)
    midi_pitch_bend: f32,
    midi_mod_wheel: f32,
    scene_index: f32,
    scene_transition: f32,

    // カスタムパラメータ (16 bytes)
    custom_params: [f32; 4],
}
```

### AnalysisData

```rust
pub struct AnalysisData {
    rms: f32,           // RMSレベル
    peak: f32,          // ピークレベル
    bass: f32,          // 低音 (20-200Hz)
    mid: f32,           // 中音 (200-2000Hz)
    high: f32,          // 高音 (2000-20000Hz)
    beat_detected: bool,
    beat_intensity: f32,
    spectrum: Vec<f32>, // 正規化スペクトラム
    timestamp: f64,
}
```

---

## スレッド設計

### メインスレッド

- winit EventLoop
- wgpu レンダリング
- MIDI イベント処理
- 動画エンコード（将来的に分離可能）

### オーディオスレッド（cpal callback内）

- デコードデータの再生
- リングバッファへの書き込み

### （将来）解析スレッド

- FFT処理
- ビート検出
- 現在はメインスレッドで実行

---

## シェーダー設計

### 頂点シェーダー

フルスクリーン三角形を描画:

```wgsl
@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    // 3頂点で画面全体をカバー
    let x = f32(i32(vertex_index) - 1);
    let y = f32(i32(vertex_index & 1u) * 2 - 1);
    out.position = vec4<f32>(x * 4.0, y * 4.0, 0.0, 1.0);
}
```

### フラグメントシェーダー

SDF（Signed Distance Function）ベースのビジュアル:

- ジオメトリック: 円、正方形、リング
- パーティクル: 点群シミュレーション
- フラクタル: マンデルブロ集合等

---

## メモリ管理

### バジェット（1時間録画時）

| 領域 | サイズ | 備考 |
|------|--------|------|
| GPU VRAM | ~170 MB | レンダーターゲット + シェーダー |
| フレームキュー | ~1.4 GB | 3秒分バッファ（180フレーム） |
| エンコーダー | ~500 MB | video-rs内部バッファ |
| **合計RAM** | **~2 GB** | |

### リソース解放戦略

- フレームはエンコード完了後すぐに解放
- オーディオバッファはリングバッファで固定サイズ
- テクスチャはダブルバッファリング

---

## エラーハンドリング

### WaveError列挙型

```rust
pub enum WaveError {
    Audio(String),      // cpal/symphoniaエラー
    Decode(String),     // デコードエラー
    Graphics(String),   // wgpuエラー
    Midi(String),       // midirエラー
    Encode(String),     // video-rsエラー
    Preset(String),     // KDLパースエラー
    Io(std::io::Error), // ファイルI/O
    Config(String),     // 設定エラー
    Channel(String),    // スレッド間通信
}
```

### リカバリー戦略

| エラー | 対処 |
|--------|------|
| オーディオデバイス切断 | 再接続を試行、失敗時は無音で続行 |
| MIDI切断 | 自動再接続、最後の状態を保持 |
| フレームドロップ | ログ出力、次フレームで補間 |
| エンコードエラー | 録画停止、ファイル保存を試行 |

---

## 将来の拡張

### Phase 2: 高度な解析

- BPM自動検出
- オンセット検出
- スペクトラム可視化

### Phase 3: MIDI 2.0

- Per-Note Expression対応
- 高解像度CC (16bit)
- カスタムプロファイル

### Phase 4: マルチシェーダー

- シェーダー間トランジション
- レイヤー合成
- ポストプロセス効果
