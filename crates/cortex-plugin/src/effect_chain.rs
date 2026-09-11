//! エフェクトチェーン
//!
//! 複数のエフェクトプラグインを直列に接続して処理する。
//! REQ-PLUGIN-004: エフェクトチェーン

use rack::prelude::*;

use crate::error::{PluginError, PluginResult};
use crate::slot::PluginSlot;

/// エフェクトチェーン — エフェクトプラグインの直列処理
pub struct EffectChain {
    /// エフェクトスロットのリスト（直列順）
    slots: Vec<PluginSlot>,
}

impl EffectChain {
    /// 空のエフェクトチェーンを作成
    pub fn new() -> Self {
        Self { slots: Vec::new() }
    }

    /// エフェクトを末尾に追加
    pub fn push(
        &mut self,
        scanner: &Scanner,
        info: &PluginInfo,
        sample_rate: f64,
        max_buffer_size: usize,
    ) -> PluginResult<()> {
        if info.plugin_type != PluginType::Effect {
            return Err(PluginError::Load(format!(
                "{} is not an effect plugin",
                info.name
            )));
        }
        let slot = PluginSlot::load(scanner, info, sample_rate, max_buffer_size)?;
        self.slots.push(slot);
        Ok(())
    }

    /// 指定インデックスのエフェクトを削除
    pub fn remove(&mut self, index: usize) -> Option<PluginSlot> {
        if index < self.slots.len() {
            Some(self.slots.remove(index))
        } else {
            None
        }
    }

    /// エフェクトチェーンを通してオーディオを処理（in-place）
    ///
    /// 各エフェクトが順番に left/right バッファを処理する。
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32], num_frames: usize) {
        for slot in &mut self.slots {
            slot.process_effect(left, right, num_frames);
        }
    }

    /// チェーン内のエフェクト数
    pub fn len(&self) -> usize {
        self.slots.len()
    }

    /// チェーンが空かどうか
    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    /// 指定インデックスのスロットへの参照
    pub fn get(&self, index: usize) -> Option<&PluginSlot> {
        self.slots.get(index)
    }

    /// 指定インデックスのスロットへの可変参照
    pub fn get_mut(&mut self, index: usize) -> Option<&mut PluginSlot> {
        self.slots.get_mut(index)
    }

    /// 全エフェクトをバイパス設定
    pub fn set_all_bypass(&mut self, bypass: bool) {
        for slot in &mut self.slots {
            slot.set_bypass(bypass);
        }
    }

    /// 全エフェクトを削除
    pub fn clear(&mut self) {
        self.slots.clear();
    }
}

impl Default for EffectChain {
    fn default() -> Self {
        Self::new()
    }
}
