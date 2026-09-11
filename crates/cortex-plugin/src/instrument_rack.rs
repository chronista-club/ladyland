//! インストゥルメントラック
//!
//! 8 スロットのインストゥルメントを常駐させ、選択で切り替える（design/05 §7 S-A）。
//! 全スロットをロードしたまま、`process` は**選択中 + リリース中の最大 2 つ**に絞る。
//! 切替時に前スロットを即停止すると音がブツ切れになるため、
//! All Notes Off を送った上でリリースを鳴らし切ってから処理対象から外す。

use crate::instrument::InstrumentSlot;
use crate::midi_convert::MidiEvent;

/// ラックのスロット数（LPD8 のパッド 1-8 に対応）
pub const NUM_SLOTS: usize = 8;

/// リリース終了とみなす無音閾値（ピーク、約 -72dBFS）
const SILENCE_THRESHOLD: f32 = 2.5e-4;

/// リリース終了とみなす連続無音時間（秒）
const SILENCE_DURATION_SECS: f64 = 0.25;

/// リリース処理のハードキャップ（秒）。長リリース音源でもここで打ち切る
const RELEASE_CAP_SECS: f64 = 8.0;

/// リリース中スロットの状態
struct Releasing {
    /// スロットインデックス
    index: usize,
    /// 残り処理サンプル数（ハードキャップ）
    remaining_samples: u64,
    /// 連続無音サンプル数
    silent_samples: u64,
}

/// インストゥルメントラック
///
/// `InstrumentSlot` を 8 つ保持し、選択中のスロットに MIDI をルーティングする。
/// リリース中のスロットは最大 1 つ（process 対象は選択中と合わせて最大 2 つ）。
pub struct InstrumentRack {
    /// スロット（全て常駐、process は選択中 + リリース中のみ）
    slots: [InstrumentSlot; NUM_SLOTS],
    /// 選択中のスロットインデックス
    selected: usize,
    /// リリース中のスロット（最大 1 つ）
    releasing: Option<Releasing>,
    /// サンプルレート（無音時間の換算に使用）
    sample_rate: f64,
}

impl InstrumentRack {
    /// 空のラックを作成
    pub fn new(sample_rate: f64) -> Self {
        Self {
            slots: std::array::from_fn(|_| InstrumentSlot::new()),
            selected: 0,
            releasing: None,
            sample_rate: sample_rate.max(1.0),
        }
    }

    /// 選択中のスロットインデックス
    pub fn selected_index(&self) -> usize {
        self.selected
    }

    /// スロットを選択する
    ///
    /// 旧選択スロットには All Notes Off + サスティンオフを送り、リリース状態に移す。
    /// 既にリリース中のスロットがある場合はそれを即終了する（process 対象を
    /// 最大 2 つに保つ）。範囲外のインデックスは無視する。
    pub fn select(&mut self, index: usize) {
        if index >= NUM_SLOTS {
            tracing::warn!("InstrumentRack: slot index {} out of range", index);
            return;
        }
        if index == self.selected {
            return;
        }

        // 3 スロット目の process を許さない: 前のリリースは打ち切る
        if let Some(old) = self.releasing.take() {
            tracing::debug!(
                "InstrumentRack: cutting short release of slot {}",
                old.index
            );
        }

        let prev = self.selected;
        if self.slots[prev].is_loaded() {
            if let Err(e) = self.slots[prev].send_midi(&all_notes_off()) {
                tracing::warn!(
                    "InstrumentRack: all-notes-off failed on slot {}: {}",
                    prev,
                    e
                );
            }
            self.releasing = Some(Releasing {
                index: prev,
                remaining_samples: (RELEASE_CAP_SECS * self.sample_rate) as u64,
                silent_samples: 0,
            });
        }

        self.selected = index;
        tracing::info!(
            "InstrumentRack: slot {} selected (slot {} releasing)",
            index,
            prev
        );
    }

    /// 指定スロットにインストゥルメントをロードする
    pub fn load_into(
        &mut self,
        index: usize,
        scanner: &rack::prelude::Scanner,
        info: &rack::prelude::PluginInfo,
        sample_rate: f64,
        max_buffer_size: usize,
    ) -> crate::error::PluginResult<()> {
        if index >= NUM_SLOTS {
            return Err(crate::error::PluginError::Load(format!(
                "slot index {} out of range (0-{})",
                index,
                NUM_SLOTS - 1
            )));
        }
        // ロード対象がリリース中なら追跡を破棄（新しい音源に引き継がない）
        if self.releasing.as_ref().is_some_and(|r| r.index == index) {
            self.releasing = None;
        }
        self.slots[index].load(scanner, info, sample_rate, max_buffer_size)
    }

    /// 選択中のスロットへの参照
    pub fn selected_slot(&self) -> &InstrumentSlot {
        &self.slots[self.selected]
    }

    /// 選択中のスロットへの可変参照
    pub fn selected_slot_mut(&mut self) -> &mut InstrumentSlot {
        &mut self.slots[self.selected]
    }

    /// 指定スロットへの参照
    pub fn slot(&self, index: usize) -> Option<&InstrumentSlot> {
        self.slots.get(index)
    }

    /// リリース中のスロットインデックス（テスト・表示用）
    pub fn releasing_index(&self) -> Option<usize> {
        self.releasing.as_ref().map(|r| r.index)
    }

    /// ロード済みスロットの一覧: (index, プラグイン名)
    pub fn loaded_slots(&self) -> Vec<(usize, &str)> {
        self.slots
            .iter()
            .enumerate()
            .filter_map(|(i, s)| s.slot().map(|p| (i, p.name())))
            .collect()
    }

    /// MIDI イベントを選択中のスロットに送信
    pub fn send_midi(&mut self, events: &[MidiEvent]) -> crate::error::PluginResult<()> {
        self.slots[self.selected].send_midi(events)
    }

    /// 音声を生成（出力バッファに加算）
    ///
    /// process 対象は選択中 + リリース中の最大 2 スロット。
    /// リリース中のスロットは無音が続くかハードキャップで処理対象から外れる。
    pub fn process_additive(
        &mut self,
        left_out: &mut [f32],
        right_out: &mut [f32],
        num_frames: usize,
        scratch_left: &mut [f32],
        scratch_right: &mut [f32],
    ) {
        // 選択中のスロット
        self.slots[self.selected].process_additive(
            left_out,
            right_out,
            num_frames,
            scratch_left,
            scratch_right,
        );

        // リリース中のスロット
        if let Some(ref mut rel) = self.releasing {
            scratch_left[..num_frames].fill(0.0);
            scratch_right[..num_frames].fill(0.0);

            // process_additive を再利用すると scratch が二重に要るため、
            // ここではスロットを直接叩いてピーク検出と加算を一度に行う
            if let Some(slot) = self.slots[rel.index].slot_mut() {
                slot.process_instrument(scratch_left, scratch_right, num_frames);
            }

            let gain = self.slots[rel.index].gain();
            let mut peak = 0.0f32;
            for i in 0..num_frames {
                left_out[i] += scratch_left[i] * gain;
                right_out[i] += scratch_right[i] * gain;
                peak = peak.max(scratch_left[i].abs()).max(scratch_right[i].abs());
            }

            // 終了判定: 連続無音 or ハードキャップ
            if peak < SILENCE_THRESHOLD {
                rel.silent_samples += num_frames as u64;
            } else {
                rel.silent_samples = 0;
            }
            rel.remaining_samples = rel.remaining_samples.saturating_sub(num_frames as u64);

            let silence_limit = (SILENCE_DURATION_SECS * self.sample_rate) as u64;
            if rel.silent_samples >= silence_limit || rel.remaining_samples == 0 {
                tracing::debug!("InstrumentRack: slot {} release finished", rel.index);
                self.releasing = None;
            }
        }
    }
}

/// 全チャンネルへの All Notes Off (CC 123) + サスティンオフ (CC 64 = 0)
///
/// サスティンペダルが踏まれたまま切り替わるとノートオフ後も鳴り続けるため、
/// CC 64 = 0 を併せて送る。
fn all_notes_off() -> Vec<MidiEvent> {
    (0..16u8)
        .flat_map(|channel| {
            [
                MidiEvent::ControlChange {
                    channel,
                    control: 64,
                    value: 0,
                },
                MidiEvent::ControlChange {
                    channel,
                    control: 123,
                    value: 0,
                },
            ]
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f64 = 48000.0;

    fn process_silence(rack: &mut InstrumentRack, frames: usize) {
        let mut left = vec![0.0f32; frames];
        let mut right = vec![0.0f32; frames];
        let mut scratch_l = vec![0.0f32; frames];
        let mut scratch_r = vec![0.0f32; frames];
        rack.process_additive(
            &mut left,
            &mut right,
            frames,
            &mut scratch_l,
            &mut scratch_r,
        );
    }

    #[test]
    fn test_initial_state() {
        let rack = InstrumentRack::new(SR);
        assert_eq!(rack.selected_index(), 0);
        assert_eq!(rack.releasing_index(), None);
        assert!(rack.loaded_slots().is_empty());
    }

    #[test]
    fn test_select_same_slot_is_noop() {
        let mut rack = InstrumentRack::new(SR);
        rack.select(0);
        assert_eq!(rack.selected_index(), 0);
        assert_eq!(rack.releasing_index(), None);
    }

    #[test]
    fn test_select_out_of_range_is_ignored() {
        let mut rack = InstrumentRack::new(SR);
        rack.select(NUM_SLOTS);
        assert_eq!(rack.selected_index(), 0);
    }

    #[test]
    fn test_select_empty_slot_does_not_release() {
        // 空スロットからの切替はリリース追跡を作らない
        let mut rack = InstrumentRack::new(SR);
        rack.select(3);
        assert_eq!(rack.selected_index(), 3);
        assert_eq!(rack.releasing_index(), None);
    }

    #[test]
    fn test_process_with_empty_slots_does_not_panic() {
        let mut rack = InstrumentRack::new(SR);
        rack.select(5);
        process_silence(&mut rack, 512);
        assert_eq!(rack.selected_index(), 5);
    }

    #[test]
    fn test_all_notes_off_covers_all_channels() {
        let events = all_notes_off();
        // 16ch × (CC64 + CC123)
        assert_eq!(events.len(), 32);
        let cc123 = events
            .iter()
            .filter(|e| matches!(e, MidiEvent::ControlChange { control: 123, .. }))
            .count();
        let cc64 = events
            .iter()
            .filter(|e| {
                matches!(
                    e,
                    MidiEvent::ControlChange {
                        control: 64,
                        value: 0,
                        ..
                    }
                )
            })
            .count();
        assert_eq!(cc123, 16);
        assert_eq!(cc64, 16);
    }
}
