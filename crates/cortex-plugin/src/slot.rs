//! プラグインスロット
//!
//! 単一プラグインの所有、バッファ管理、処理を担当する。
//! REQ-PLUGIN-003: プラグインスロット管理

use rack::prelude::*;

use crate::error::{PluginError, PluginResult};
use crate::midi_convert::{self, MidiEvent};

/// プラグインスロット — 単一プラグインのラッパー
///
/// スクラッチバッファを事前アロケートし、ゼロアロケーション処理を実現する。
pub struct PluginSlot {
    /// rack プラグインインスタンス
    plugin: Plugin,
    /// プラグイン情報
    info: PluginInfo,
    /// バイパス状態
    bypass: bool,
    /// スクラッチバッファ（入力用）
    scratch_in_left: Vec<f32>,
    scratch_in_right: Vec<f32>,
    /// スクラッチバッファ（出力用）
    scratch_out_left: Vec<f32>,
    scratch_out_right: Vec<f32>,
    /// 最大バッファサイズ
    max_buffer_size: usize,
}

impl PluginSlot {
    /// スキャナーからプラグインをロードして初期化する
    pub fn load(
        scanner: &Scanner,
        info: &PluginInfo,
        sample_rate: f64,
        max_buffer_size: usize,
    ) -> PluginResult<Self> {
        let mut plugin = scanner
            .load(info)
            .map_err(|e| PluginError::Load(format!("{}: {}", info.name, e)))?;

        plugin
            .initialize(sample_rate, max_buffer_size)
            .map_err(|e| PluginError::Initialize(format!("{}: {}", info.name, e)))?;

        tracing::info!(
            "PluginSlot loaded: {} by {} ({:?})",
            info.name,
            info.manufacturer,
            info.plugin_type
        );

        Ok(Self {
            plugin,
            info: info.clone(),
            bypass: false,
            scratch_in_left: vec![0.0; max_buffer_size],
            scratch_in_right: vec![0.0; max_buffer_size],
            scratch_out_left: vec![0.0; max_buffer_size],
            scratch_out_right: vec![0.0; max_buffer_size],
            max_buffer_size,
        })
    }

    /// エフェクト処理（in-place）
    ///
    /// 入力バッファを読み取り、処理結果で上書きする。
    /// max_buffer_size を超えるフレームはチャンク分割して処理する。
    pub fn process_effect(&mut self, left: &mut [f32], right: &mut [f32], num_frames: usize) {
        if self.bypass || num_frames == 0 {
            return;
        }

        let mut offset = 0;
        while offset < num_frames {
            let chunk = (num_frames - offset).min(self.max_buffer_size);

            // 入力をスクラッチバッファにコピー
            self.scratch_in_left[..chunk].copy_from_slice(&left[offset..offset + chunk]);
            self.scratch_in_right[..chunk].copy_from_slice(&right[offset..offset + chunk]);

            // 出力バッファをクリア
            self.scratch_out_left[..chunk].fill(0.0);
            self.scratch_out_right[..chunk].fill(0.0);

            let result = self.plugin.process(
                &[
                    &self.scratch_in_left[..chunk],
                    &self.scratch_in_right[..chunk],
                ],
                &mut [
                    &mut self.scratch_out_left[..chunk],
                    &mut self.scratch_out_right[..chunk],
                ],
                chunk,
            );

            if result.is_ok() {
                left[offset..offset + chunk].copy_from_slice(&self.scratch_out_left[..chunk]);
                right[offset..offset + chunk].copy_from_slice(&self.scratch_out_right[..chunk]);
            }

            offset += chunk;
        }
    }

    /// インストゥルメント処理（無音入力→音声生成）
    ///
    /// MIDI ノートに基づいて音声を生成し、出力バッファに書き込む。
    /// max_buffer_size を超えるフレームはチャンク分割して処理する。
    pub fn process_instrument(
        &mut self,
        left_out: &mut [f32],
        right_out: &mut [f32],
        num_frames: usize,
    ) {
        if self.bypass || num_frames == 0 {
            return;
        }

        let mut offset = 0;
        while offset < num_frames {
            let chunk = (num_frames - offset).min(self.max_buffer_size);

            // インストゥルメントには無音を入力
            self.scratch_in_left[..chunk].fill(0.0);
            self.scratch_in_right[..chunk].fill(0.0);

            // 出力バッファをクリア
            self.scratch_out_left[..chunk].fill(0.0);
            self.scratch_out_right[..chunk].fill(0.0);

            let result = self.plugin.process(
                &[
                    &self.scratch_in_left[..chunk],
                    &self.scratch_in_right[..chunk],
                ],
                &mut [
                    &mut self.scratch_out_left[..chunk],
                    &mut self.scratch_out_right[..chunk],
                ],
                chunk,
            );

            if result.is_ok() {
                left_out[offset..offset + chunk].copy_from_slice(&self.scratch_out_left[..chunk]);
                right_out[offset..offset + chunk].copy_from_slice(&self.scratch_out_right[..chunk]);
            }

            offset += chunk;
        }
    }

    /// MIDI イベントを送信
    pub fn send_midi(&mut self, events: &[MidiEvent]) -> PluginResult<()> {
        let rack_events = midi_convert::to_rack_midi_batch(events);
        if rack_events.is_empty() {
            return Ok(());
        }
        self.plugin
            .send_midi(&rack_events)
            .map_err(|e| PluginError::MidiSend(format!("{}: {}", self.info.name, e)))
    }

    /// パラメータを設定
    pub fn set_parameter(&mut self, index: usize, value: f32) -> PluginResult<()> {
        self.plugin
            .set_parameter(index, value)
            .map_err(|e| PluginError::Parameter(format!("{}: {}", self.info.name, e)))
    }

    /// パラメータを取得
    pub fn get_parameter(&self, index: usize) -> PluginResult<f32> {
        self.plugin
            .get_parameter(index)
            .map_err(|e| PluginError::Parameter(format!("{}: {}", self.info.name, e)))
    }

    /// パラメータ数を取得
    pub fn parameter_count(&self) -> usize {
        self.plugin.parameter_count()
    }

    /// パラメータ情報を取得
    pub fn parameter_info(&self, index: usize) -> PluginResult<ParameterInfo> {
        self.plugin
            .parameter_info(index)
            .map_err(|e| PluginError::Parameter(format!("{}: {}", self.info.name, e)))
    }

    /// バイパス状態を設定
    pub fn set_bypass(&mut self, bypass: bool) {
        self.bypass = bypass;
    }

    /// バイパス状態を取得
    pub fn is_bypassed(&self) -> bool {
        self.bypass
    }

    /// プラグイン情報を取得
    pub fn info(&self) -> &PluginInfo {
        &self.info
    }

    /// プラグイン名を取得
    pub fn name(&self) -> &str {
        &self.info.name
    }

    /// プラグインタイプを取得
    pub fn plugin_type(&self) -> PluginType {
        self.info.plugin_type
    }
}
