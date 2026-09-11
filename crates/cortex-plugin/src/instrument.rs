//! インストゥルメントスロット
//!
//! MIDIノートを受けて音声を生成するプラグインを管理する。
//! REQ-PLUGIN-005: インストゥルメント管理

use rack::prelude::*;

use crate::error::{PluginError, PluginResult};
use crate::midi_convert::MidiEvent;
use crate::slot::PluginSlot;

/// インストゥルメントスロット
///
/// MIDI入力を受けて音声を生成するプラグインのラッパー。
pub struct InstrumentSlot {
    /// 内部のプラグインスロット
    slot: Option<PluginSlot>,
    /// 出力ゲイン（0.0 - 1.0）
    gain: f32,
}

impl InstrumentSlot {
    /// 空のインストゥルメントスロットを作成
    pub fn new() -> Self {
        Self {
            slot: None,
            gain: 1.0,
        }
    }

    /// インストゥルメントプラグインをロード
    pub fn load(
        &mut self,
        scanner: &Scanner,
        info: &PluginInfo,
        sample_rate: f64,
        max_buffer_size: usize,
    ) -> PluginResult<()> {
        if info.plugin_type != PluginType::Instrument {
            return Err(PluginError::Load(format!(
                "{} is not an instrument plugin",
                info.name
            )));
        }
        let slot = PluginSlot::load(scanner, info, sample_rate, max_buffer_size)?;
        self.slot = Some(slot);
        Ok(())
    }

    /// インストゥルメントをアンロード
    pub fn unload(&mut self) {
        self.slot = None;
    }

    /// 音声を生成（出力バッファに加算）
    ///
    /// 既存の出力バッファに生成音声をミックスする。
    pub fn process_additive(
        &mut self,
        left_out: &mut [f32],
        right_out: &mut [f32],
        num_frames: usize,
        scratch_left: &mut [f32],
        scratch_right: &mut [f32],
    ) {
        if let Some(ref mut slot) = self.slot {
            // スクラッチバッファをクリアしてインストゥルメント処理
            scratch_left[..num_frames].fill(0.0);
            scratch_right[..num_frames].fill(0.0);

            slot.process_instrument(scratch_left, scratch_right, num_frames);

            // ゲインを適用して加算ミックス
            for i in 0..num_frames {
                left_out[i] += scratch_left[i] * self.gain;
                right_out[i] += scratch_right[i] * self.gain;
            }
        }
    }

    /// MIDI イベントを送信
    pub fn send_midi(&mut self, events: &[MidiEvent]) -> PluginResult<()> {
        if let Some(ref mut slot) = self.slot {
            slot.send_midi(events)
        } else {
            Ok(()) // プラグインがない場合は無視
        }
    }

    /// 出力ゲインを設定
    pub fn set_gain(&mut self, gain: f32) {
        self.gain = gain.clamp(0.0, 2.0);
    }

    /// 出力ゲインを取得
    pub fn gain(&self) -> f32 {
        self.gain
    }

    /// プラグインがロードされているか
    pub fn is_loaded(&self) -> bool {
        self.slot.is_some()
    }

    /// 内部スロットへの参照
    pub fn slot(&self) -> Option<&PluginSlot> {
        self.slot.as_ref()
    }

    /// 内部スロットへの可変参照
    pub fn slot_mut(&mut self) -> Option<&mut PluginSlot> {
        self.slot.as_mut()
    }
}

impl Default for InstrumentSlot {
    fn default() -> Self {
        Self::new()
    }
}
