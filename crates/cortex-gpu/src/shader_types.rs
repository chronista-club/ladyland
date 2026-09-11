//! シェーダーユニフォーム定義
//!
//! REQ-CORE-004: GPU転送用データ構造

use bytemuck::{Pod, Zeroable};

/// シェーダーユニフォーム構造体
///
/// GPU転送用のデータ構造。WGSLのアライメントルールに合わせて設計:
/// - vec2<f32>: 8バイトアライメント
/// - vec4<f32>: 16バイトアライメント
///
/// 合計サイズ: 128バイト
#[repr(C)]
#[derive(Debug, Clone, Copy, Pod, Zeroable)]
pub struct ShaderUniforms {
    // === 時間・解像度 (offset 0-16) ===
    /// 経過時間（秒）
    pub time: f32,                  // offset 0
    /// パディング（vec2のアライメント用）
    _pad0: f32,                     // offset 4
    /// 解像度 [width, height]
    pub resolution: [f32; 2],       // offset 8
    /// デルタタイム（前フレームからの経過時間）
    pub delta_time: f32,            // offset 16

    // === オーディオ解析 (offset 20-36) ===
    /// RMSレベル
    pub rms: f32,                   // offset 20
    /// 低音帯域エネルギー
    pub bass: f32,                  // offset 24
    /// 中音帯域エネルギー
    pub mid: f32,                   // offset 28
    /// 高音帯域エネルギー
    pub high: f32,                  // offset 32

    // === ビート情報 (offset 36-52) ===
    /// ビート強度 (0.0 - 1.0)
    pub beat_intensity: f32,        // offset 36
    /// ビートカウント
    pub beat_count: f32,            // offset 40
    /// ビート間隔（BPMから計算）
    pub beat_interval: f32,         // offset 44
    /// 最後のビートからの経過時間
    pub time_since_beat: f32,       // offset 48

    // === パディング (vec4アライメント用) ===
    _pad1: [f32; 3],                // offset 52-64

    // === MIDI CC (offset 64-96) ===
    /// MIDIコントロールチェンジ値 [0-7]
    /// WGSLでは midi_cc_0_3: vec4<f32> と midi_cc_4_7: vec4<f32> に対応
    pub midi_cc: [f32; 8],          // offset 64

    // === MIDI追加情報 (offset 96-112) ===
    /// ピッチベンド (-1.0 to 1.0)
    pub midi_pitch_bend: f32,       // offset 96
    /// モジュレーションホイール (0.0 to 1.0)
    pub midi_mod_wheel: f32,        // offset 100
    /// 現在のシーンインデックス
    pub scene_index: f32,           // offset 104
    /// シーントランジション進捗 (0.0 to 1.0)
    pub scene_transition: f32,      // offset 108

    // === ユーザーパラメータ (offset 112-128) ===
    /// カスタムパラメータ [0-3]
    /// WGSLでは custom_params: vec4<f32> に対応
    pub custom_params: [f32; 4],    // offset 112
}

impl Default for ShaderUniforms {
    fn default() -> Self {
        Self {
            time: 0.0,
            _pad0: 0.0,
            resolution: [1920.0, 1080.0],
            delta_time: 1.0 / 60.0,
            rms: 0.0,
            bass: 0.0,
            mid: 0.0,
            high: 0.0,
            beat_intensity: 0.0,
            beat_count: 0.0,
            beat_interval: 0.5, // 120 BPM default
            time_since_beat: 0.0,
            _pad1: [0.0; 3],
            midi_cc: [0.0; 8],
            midi_pitch_bend: 0.0,
            midi_mod_wheel: 0.0,
            scene_index: 0.0,
            scene_transition: 0.0,
            custom_params: [0.0; 4],
        }
    }
}

impl ShaderUniforms {
    /// 新しいShaderUniformsを作成
    pub fn new() -> Self {
        Self::default()
    }

    /// オーディオ解析データを適用
    pub fn apply_analysis(&mut self, analysis: &cortex_types::AnalysisData) {
        self.rms = analysis.rms;
        self.bass = analysis.bass;
        self.mid = analysis.mid;
        self.high = analysis.high;
        self.beat_intensity = analysis.beat_intensity;
        if analysis.beat_detected {
            self.beat_count += 1.0;
            self.time_since_beat = 0.0;
        }
    }

    /// 時間を更新
    pub fn update_time(&mut self, time: f32, delta: f32) {
        self.time = time;
        self.delta_time = delta;
        self.time_since_beat += delta;
    }

    /// MIDI CC値を設定
    pub fn set_midi_cc(&mut self, index: usize, value: f32) {
        if index < 8 {
            self.midi_cc[index] = value;
        }
    }
}

/// エンコード設定
#[derive(Debug, Clone)]
pub struct EncoderConfig {
    /// 出力幅（ピクセル）
    pub width: u32,
    /// 出力高さ（ピクセル）
    pub height: u32,
    /// フレームレート
    pub fps: u32,
    /// ビットレート (bps)
    pub bitrate: u32,
    /// コーデック
    pub codec: VideoCodec,
    /// エンコードプリセット
    pub preset: EncoderPreset,
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 20_000_000, // 20 Mbps
            codec: VideoCodec::H264,
            preset: EncoderPreset::Ultrafast,
        }
    }
}

/// ビデオコーデック
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    H264,
    H265,
    VP9,
}

/// エンコードプリセット
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EncoderPreset {
    /// リアルタイム向け（最速）
    Ultrafast,
    /// バランス
    Medium,
    /// 高品質（遅い）
    Slow,
}

/// レンダリング設定
#[derive(Debug, Clone)]
pub struct RenderConfig {
    /// ウィンドウ幅
    pub width: u32,
    /// ウィンドウ高さ
    pub height: u32,
    /// フルスクリーン
    pub fullscreen: bool,
    /// VSync有効
    pub vsync: bool,
    /// ターゲットFPS
    pub target_fps: u32,
}

impl Default for RenderConfig {
    fn default() -> Self {
        Self {
            width: 1920,
            height: 1080,
            fullscreen: false,
            vsync: true,
            target_fps: 60,
        }
    }
}
