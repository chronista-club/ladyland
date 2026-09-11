//! パラメータブリッジ
//!
//! MIDI CC → プラグインパラメータのマッピングを提供する。
//! CC 値のスムージング（指数移動平均）でノイズを防止。
//! REQ-PLUGIN-008: CC→パラメータマッピング

use crate::midi_convert::MidiEvent;

/// エフェクト用 CC の開始番号 (CC 20-27)
const EFFECT_CC_START: u8 = 20;
/// エフェクト用 CC のスロット数
const EFFECT_CC_COUNT: u8 = 8;
/// デフォルトのスムージング係数 (0.0=変化なし, 1.0=即座)
const DEFAULT_SMOOTHING: f32 = 0.15;
/// 値の変化がこの閾値以下なら送信しない
const CHANGE_THRESHOLD: f32 = 0.001;

/// CC→パラメータのマッピングエントリ
#[derive(Debug, Clone)]
pub struct ParamMapping {
    /// MIDI CC 番号
    pub cc: u8,
    /// エフェクトチェーン内のインデックス (None = インストゥルメント)
    pub target: ParamTarget,
    /// プラグインパラメータインデックス
    pub param_index: usize,
    /// マッピング範囲の最小値
    pub min_value: f32,
    /// マッピング範囲の最大値
    pub max_value: f32,
}

/// パラメータの送信先
#[derive(Debug, Clone)]
pub enum ParamTarget {
    /// エフェクトチェーン内のスロット
    Effect { chain_index: usize },
    /// インストゥルメント
    Instrument,
}

/// スムージング状態
#[derive(Debug, Clone)]
struct SmoothState {
    /// 現在の補間値
    current: f32,
    /// ターゲット値（CC から計算した最終目標）
    target: f32,
    /// 値が設定されたか
    active: bool,
}

/// CC 値から変換されたパラメータ変更
#[derive(Debug)]
pub struct ParamChange {
    /// 送信先
    pub target: ParamTarget,
    /// パラメータインデックス
    pub param_index: usize,
    /// 変換後の値
    pub value: f32,
}

/// パラメータブリッジ
///
/// MIDI CC メッセージをプラグインパラメータ変更に変換する。
/// 指数移動平均でスムージングし、バリバリノイズを防止する。
pub struct ParamBridge {
    /// マッピングテーブル
    mappings: Vec<ParamMapping>,
    /// スムージング状態 (mappings と同じインデックス)
    smooth_states: Vec<SmoothState>,
    /// スムージング係数
    smoothing: f32,
}

impl ParamBridge {
    /// 空のパラメータブリッジを作成
    pub fn new() -> Self {
        Self {
            mappings: Vec::new(),
            smooth_states: Vec::new(),
            smoothing: DEFAULT_SMOOTHING,
        }
    }

    /// マッピングを追加
    pub fn add_mapping(&mut self, mapping: ParamMapping) {
        self.mappings.push(mapping);
        self.smooth_states.push(SmoothState {
            current: 0.0,
            target: 0.0,
            active: false,
        });
    }

    /// CC 番号に基づくマッピングを削除
    pub fn remove_mapping(&mut self, cc: u8) {
        let mut i = 0;
        while i < self.mappings.len() {
            if self.mappings[i].cc == cc {
                self.mappings.remove(i);
                self.smooth_states.remove(i);
            } else {
                i += 1;
            }
        }
    }

    /// 全マッピングをクリア
    pub fn clear(&mut self) {
        self.mappings.clear();
        self.smooth_states.clear();
    }

    /// MIDI CC イベントからターゲット値を更新する
    ///
    /// 即座にパラメータ変更を送信せず、ターゲット値のみ設定する。
    /// 実際の変更は `tick()` で滑らかに生成される。
    pub fn set_target(&mut self, event: &MidiEvent) {
        if let MidiEvent::ControlChange { control, value, .. } = event {
            let normalized = *value as f32 / 127.0;
            for (i, m) in self.mappings.iter().enumerate() {
                if m.cc == *control {
                    let mapped = m.min_value + (m.max_value - m.min_value) * normalized;
                    let state = &mut self.smooth_states[i];
                    state.target = mapped;
                    if !state.active {
                        // 初回は即座にジャンプ
                        state.current = mapped;
                        state.active = true;
                    }
                }
            }
        }
    }

    /// スムージングを1ステップ進め、変化があったパラメータ変更を返す
    ///
    /// メインループの `update()` から毎フレーム呼び出す。
    pub fn tick(&mut self) -> Vec<ParamChange> {
        let mut changes = Vec::new();

        for (i, state) in self.smooth_states.iter_mut().enumerate() {
            if !state.active {
                continue;
            }

            let diff = state.target - state.current;
            if diff.abs() < CHANGE_THRESHOLD {
                // 十分近い → ターゲットにスナップ
                if (state.current - state.target).abs() > f32::EPSILON {
                    state.current = state.target;
                    let m = &self.mappings[i];
                    changes.push(ParamChange {
                        target: m.target.clone(),
                        param_index: m.param_index,
                        value: state.current,
                    });
                }
                continue;
            }

            // 指数移動平均
            state.current += diff * self.smoothing;
            let m = &self.mappings[i];
            changes.push(ParamChange {
                target: m.target.clone(),
                param_index: m.param_index,
                value: state.current,
            });
        }

        changes
    }

    /// MIDI イベントからパラメータ変更を生成（スムージングなし・後方互換）
    ///
    /// CC メッセージのみを処理し、マッピングに基づいてパラメータ変更を返す。
    pub fn process_event(&self, event: &MidiEvent) -> Vec<ParamChange> {
        match event {
            MidiEvent::ControlChange { control, value, .. } => {
                let normalized = *value as f32 / 127.0;
                self.mappings
                    .iter()
                    .filter(|m| m.cc == *control)
                    .map(|m| {
                        let mapped_value = m.min_value + (m.max_value - m.min_value) * normalized;
                        ParamChange {
                            target: m.target.clone(),
                            param_index: m.param_index,
                            value: mapped_value,
                        }
                    })
                    .collect()
            }
            _ => Vec::new(),
        }
    }

    /// 複数のMIDIイベントからパラメータ変更を一括生成
    pub fn process_events(&self, events: &[MidiEvent]) -> Vec<ParamChange> {
        events.iter().flat_map(|e| self.process_event(e)).collect()
    }

    /// エフェクト用デフォルトマッピングを設定
    ///
    /// CC 20-27 を Effect[chain_index] の param 0-7 にマッピングする。
    /// `params` が提供されれば min/max をパラメータ情報から取得、
    /// なければ 0.0-1.0 にフォールバックする。
    pub fn setup_effect_mappings(
        &mut self,
        chain_index: usize,
        param_count: usize,
        params: &[(String, f32, f32)],
    ) {
        // 既存のエフェクト CC マッピングをクリア
        let effect_cc_range = EFFECT_CC_START..EFFECT_CC_START + EFFECT_CC_COUNT;
        let mut i = 0;
        while i < self.mappings.len() {
            if effect_cc_range.contains(&self.mappings[i].cc) {
                self.mappings.remove(i);
                self.smooth_states.remove(i);
            } else {
                i += 1;
            }
        }

        let count = param_count.min(EFFECT_CC_COUNT as usize);
        for i in 0..count {
            let (min_value, max_value) = if i < params.len() {
                (params[i].1, params[i].2)
            } else {
                (0.0, 1.0)
            };

            self.mappings.push(ParamMapping {
                cc: EFFECT_CC_START + i as u8,
                target: ParamTarget::Effect { chain_index },
                param_index: i,
                min_value,
                max_value,
            });
            self.smooth_states.push(SmoothState {
                current: 0.0,
                target: 0.0,
                active: false,
            });
        }
    }

    /// CC イベントがマッピングに該当するか
    pub fn has_mapping_for(&self, cc: u8) -> bool {
        self.mappings.iter().any(|m| m.cc == cc)
    }

    /// マッピング一覧
    pub fn mappings(&self) -> &[ParamMapping] {
        &self.mappings
    }
}

impl Default for ParamBridge {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cc_to_param() {
        let mut bridge = ParamBridge::new();
        bridge.add_mapping(ParamMapping {
            cc: 20,
            target: ParamTarget::Effect { chain_index: 0 },
            param_index: 0,
            min_value: 0.0,
            max_value: 1.0,
        });

        let event = MidiEvent::ControlChange {
            channel: 0,
            control: 20,
            value: 64, // midpoint
        };

        let changes = bridge.process_event(&event);
        assert_eq!(changes.len(), 1);
        // 64/127 ≈ 0.504
        assert!((changes[0].value - 0.504).abs() < 0.01);
    }

    #[test]
    fn test_smoothing() {
        let mut bridge = ParamBridge::new();
        bridge.add_mapping(ParamMapping {
            cc: 20,
            target: ParamTarget::Effect { chain_index: 0 },
            param_index: 0,
            min_value: 0.0,
            max_value: 100.0,
        });

        // 初回の set_target → 即座にジャンプ
        let event = MidiEvent::ControlChange {
            channel: 0,
            control: 20,
            value: 0,
        };
        bridge.set_target(&event);
        let changes = bridge.tick();
        assert!(changes.is_empty() || changes[0].value.abs() < 0.01);

        // ターゲットを 100 に設定
        let event = MidiEvent::ControlChange {
            channel: 0,
            control: 20,
            value: 127,
        };
        bridge.set_target(&event);

        // tick を繰り返すと徐々に近づく
        let mut last_value = 0.0;
        for _ in 0..50 {
            let changes = bridge.tick();
            if !changes.is_empty() {
                assert!(changes[0].value > last_value);
                last_value = changes[0].value;
            }
        }
        // 50回で 100 に十分近づいているはず
        assert!(last_value > 95.0);
    }

    #[test]
    fn test_cc_range_mapping() {
        let mut bridge = ParamBridge::new();
        bridge.add_mapping(ParamMapping {
            cc: 21,
            target: ParamTarget::Instrument,
            param_index: 5,
            min_value: 0.5,
            max_value: 2.0,
        });

        let event = MidiEvent::ControlChange {
            channel: 0,
            control: 21,
            value: 127, // max
        };

        let changes = bridge.process_event(&event);
        assert_eq!(changes.len(), 1);
        assert!((changes[0].value - 2.0).abs() < 0.01);
    }

    #[test]
    fn test_non_cc_ignored() {
        let bridge = ParamBridge::new();
        let event = MidiEvent::NoteOn {
            channel: 0,
            note: 60,
            velocity: 100,
        };
        let changes = bridge.process_event(&event);
        assert!(changes.is_empty());
    }
}
