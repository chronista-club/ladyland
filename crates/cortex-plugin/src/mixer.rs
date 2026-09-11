//! オーディオミキサー
//!
//! ファイル再生オーディオとインストゥルメント生成音声をミックスする。
//! REQ-PLUGIN-006: オーディオミキシング

use crate::instrument_rack::InstrumentRack;

/// オーディオミキサー
///
/// デコーダーからのオーディオフレームにインストゥルメント生成音声を加算ミックスする。
/// インストゥルメントは 8 スロットのラック（design/05 §7 S-A）。
pub struct AudioMixer {
    /// インストゥルメントラック（8 スロット）
    rack: InstrumentRack,
    /// ファイル再生の音量 (0.0 - 1.0)
    file_gain: f32,
    /// マスター音量 (0.0 - 1.0)
    master_gain: f32,
    /// スクラッチバッファ（インストゥルメント出力用）
    scratch_left: Vec<f32>,
    scratch_right: Vec<f32>,
}

impl AudioMixer {
    /// 新しいミキサーを作成
    pub fn new(sample_rate: f64, max_buffer_size: usize) -> Self {
        Self {
            rack: InstrumentRack::new(sample_rate),
            file_gain: 1.0,
            master_gain: 1.0,
            scratch_left: vec![0.0; max_buffer_size],
            scratch_right: vec![0.0; max_buffer_size],
        }
    }

    /// オーディオをミックス処理（in-place）
    ///
    /// 1. ファイル再生音にゲインを適用
    /// 2. インストゥルメント音声を加算（選択中 + リリース中の最大 2 スロット）
    /// 3. マスターゲインを適用
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32], num_frames: usize) {
        // ファイル再生ゲインを適用
        if (self.file_gain - 1.0).abs() > f32::EPSILON {
            for i in 0..num_frames {
                left[i] *= self.file_gain;
                right[i] *= self.file_gain;
            }
        }

        // インストゥルメント音声を加算ミックス
        self.rack.process_additive(
            left,
            right,
            num_frames,
            &mut self.scratch_left,
            &mut self.scratch_right,
        );

        // マスターゲインを適用
        if (self.master_gain - 1.0).abs() > f32::EPSILON {
            for i in 0..num_frames {
                left[i] *= self.master_gain;
                right[i] *= self.master_gain;
            }
        }
    }

    /// インストゥルメントラックへの参照
    pub fn rack(&self) -> &InstrumentRack {
        &self.rack
    }

    /// インストゥルメントラックへの可変参照
    pub fn rack_mut(&mut self) -> &mut InstrumentRack {
        &mut self.rack
    }

    /// ファイル再生ゲインを設定
    pub fn set_file_gain(&mut self, gain: f32) {
        self.file_gain = gain.clamp(0.0, 2.0);
    }

    /// マスターゲインを設定
    pub fn set_master_gain(&mut self, gain: f32) {
        self.master_gain = gain.clamp(0.0, 2.0);
    }

    /// ファイル再生ゲインを取得
    pub fn file_gain(&self) -> f32 {
        self.file_gain
    }

    /// マスターゲインを取得
    pub fn master_gain(&self) -> f32 {
        self.master_gain
    }
}
