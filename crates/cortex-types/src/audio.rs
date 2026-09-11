//! オーディオ関連のデータ型
//!
//! REQ-CORE-002: オーディオフレーム定義

use serde::{Deserialize, Serialize};

/// オーディオフレームデータ
///
/// 再生中のオーディオサンプルを保持する構造体
#[derive(Debug, Clone)]
pub struct AudioFrame {
    /// 左チャンネルのサンプル
    pub left: Vec<f32>,
    /// 右チャンネルのサンプル
    pub right: Vec<f32>,
    /// サンプルレート (Hz)
    pub sample_rate: u32,
    /// フレームタイムスタンプ (秒)
    pub timestamp: f64,
}

impl AudioFrame {
    /// 新しいAudioFrameを作成
    pub fn new(left: Vec<f32>, right: Vec<f32>, sample_rate: u32, timestamp: f64) -> Self {
        Self {
            left,
            right,
            sample_rate,
            timestamp,
        }
    }

    /// モノラルミックスを取得
    pub fn mono(&self) -> Vec<f32> {
        self.left
            .iter()
            .zip(self.right.iter())
            .map(|(l, r)| (l + r) * 0.5)
            .collect()
    }

    /// フレームの長さ（サンプル数）
    pub fn len(&self) -> usize {
        self.left.len()
    }

    /// フレームが空かどうか
    pub fn is_empty(&self) -> bool {
        self.left.is_empty()
    }
}

/// オーディオ解析結果
///
/// FFTとビート検出の結果を保持
#[derive(Debug, Clone, Default)]
pub struct AnalysisData {
    /// RMS（二乗平均平方根）レベル
    pub rms: f32,
    /// ピークレベル
    pub peak: f32,
    /// 低音帯域エネルギー (20-200Hz)
    pub bass: f32,
    /// 中音帯域エネルギー (200-2000Hz)
    pub mid: f32,
    /// 高音帯域エネルギー (2000-20000Hz)
    pub high: f32,
    /// ビート検出フラグ
    pub beat_detected: bool,
    /// ビート強度 (0.0 - 1.0)
    pub beat_intensity: f32,
    /// スペクトラムデータ（正規化済み）
    pub spectrum: Vec<f32>,
    /// タイムスタンプ
    pub timestamp: f64,
}

impl AnalysisData {
    /// 新しいAnalysisDataを作成
    pub fn new() -> Self {
        Self::default()
    }
}

/// 周波数帯域定義
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct FrequencyBand {
    /// 開始周波数 (Hz)
    pub low: f32,
    /// 終了周波数 (Hz)
    pub high: f32,
}

impl FrequencyBand {
    /// 低音帯域 (20-200Hz)
    pub const BASS: Self = Self {
        low: 20.0,
        high: 200.0,
    };
    /// 中音帯域 (200-2000Hz)
    pub const MID: Self = Self {
        low: 200.0,
        high: 2000.0,
    };
    /// 高音帯域 (2000-20000Hz)
    pub const HIGH: Self = Self {
        low: 2000.0,
        high: 20000.0,
    };
}

/// オーディオ設定
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioConfig {
    /// サンプルレート (Hz)
    pub sample_rate: u32,
    /// バッファサイズ（サンプル数）
    pub buffer_size: usize,
    /// チャンネル数
    pub channels: u16,
    /// FFTサイズ
    pub fft_size: usize,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            sample_rate: 48000,
            buffer_size: 1024,
            channels: 2,
            fft_size: 2048,
        }
    }
}
