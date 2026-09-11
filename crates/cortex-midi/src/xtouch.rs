//! X-Touch (MCU プロトコル) Main フェーダー連携
//!
//! design/03-midi-focus-model.md の「演奏・音声経路は bikeboy 直取り」に基づき、
//! X-Touch INT へダイレクト接続して Main フェーダーとマスターゲインを双方向同期する。
//!
//! - 入力: Main フェーダー操作（pitch bend ch9）→ ゲイン値
//! - 出力: ゲイン値 → モーターフェーダー位置（同じ pitch bend メッセージを送出）
//! - タッチセンサー（note 0x70）押下中はモーターへのエコーバックを抑制する
//!   （ユーザーの手とモーターが喧嘩しないように）
//!
//! MCU の X-Touch 全体制御（ストリップ LCD / LED projection）は VP/Bastet のドメイン
//! （midistage-profiles の xtouch モジュール）。ここは音声経路の Main フェーダーのみ。

use midir::{MidiOutput, MidiOutputConnection};

use cortex_types::{WaveError, WaveResult};

use crate::handler::{MidiEvent, MidiHandler};

/// MCU Main フェーダーの pitch bend チャンネル（0-indexed。MIDI ch9）
const MAIN_FADER_CHANNEL: u8 = 8;
/// MCU Main フェーダーのタッチセンサー note 番号
const MAIN_FADER_TOUCH_NOTE: u8 = 0x70;
/// 14bit フェーダーの最大生値
const FADER_MAX: u16 = 16383;
/// 接続対象のポート名（部分一致）
const PORT_PATTERN: &str = "X-Touch INT";

/// フェーダー生値（0..16383）→ ゲイン（0.0..1.0、リニア。トップ = ユニティ）
pub fn raw_to_gain(raw: u16) -> f32 {
    raw.min(FADER_MAX) as f32 / FADER_MAX as f32
}

/// ゲイン（0.0..1.0）→ フェーダー生値
pub fn gain_to_raw(gain: f32) -> u16 {
    (gain.clamp(0.0, 1.0) * FADER_MAX as f32).round() as u16
}

/// Main フェーダー位置を設定する pitch bend メッセージ（モーター駆動用）
pub fn main_fader_message(raw: u16) -> [u8; 3] {
    let raw = raw.min(FADER_MAX);
    [
        0xE0 | MAIN_FADER_CHANNEL,
        (raw & 0x7F) as u8,
        (raw >> 7) as u8,
    ]
}

/// Main フェーダーの入力解釈（純粋部分、I/O なしでテスト可能）
#[derive(Debug, Default)]
pub struct MainFaderState {
    touched: bool,
}

impl MainFaderState {
    /// MIDI イベントを適用する。フェーダーが動いた場合のみ生値を返す。
    pub fn apply(&mut self, event: &MidiEvent) -> Option<u16> {
        match event {
            MidiEvent::PitchBend { channel, value } if *channel == MAIN_FADER_CHANNEL => {
                // handler の PitchBend value は raw 14bit（0..16383）
                Some((*value).clamp(0, FADER_MAX as i16) as u16)
            }
            MidiEvent::NoteOn { note, velocity, .. } if *note == MAIN_FADER_TOUCH_NOTE => {
                // MCU のタッチは NoteOn velocity 0x7F / 離すと velocity 0
                self.touched = *velocity > 0;
                None
            }
            MidiEvent::NoteOff { note, .. } if *note == MAIN_FADER_TOUCH_NOTE => {
                self.touched = false;
                None
            }
            _ => None,
        }
    }

    /// フェーダーがタッチされているか
    pub fn touched(&self) -> bool {
        self.touched
    }
}

/// X-Touch Main フェーダー ⇄ マスターゲインの双方向同期
pub struct XTouchMainFader {
    input: MidiHandler,
    output: MidiOutputConnection,
    state: MainFaderState,
}

impl XTouchMainFader {
    /// "X-Touch INT" ポートへ入出力とも接続する
    pub fn connect() -> WaveResult<Self> {
        let mut input = MidiHandler::new()?;
        input.connect(PORT_PATTERN)?;

        let midi_out = MidiOutput::new("cortex-xtouch")
            .map_err(|e| WaveError::Midi(format!("Failed to create MIDI output: {}", e)))?;
        let ports = midi_out.ports();
        let port = ports
            .iter()
            .find(|p| {
                midi_out
                    .port_name(p)
                    .map(|n| n.contains(PORT_PATTERN))
                    .unwrap_or(false)
            })
            .ok_or_else(|| {
                WaveError::Midi(format!("Output port not found: {}", PORT_PATTERN))
            })?
            .clone();
        let output = midi_out
            .connect(&port, "cortex-xtouch-out")
            .map_err(|e| WaveError::Midi(format!("Failed to connect output: {}", e)))?;

        Ok(Self {
            input,
            output,
            state: MainFaderState::default(),
        })
    }

    /// 入力をポーリングし、フェーダー操作があれば新しいゲイン（0.0..1.0）を返す
    ///
    /// 複数イベントが溜まっていた場合は最新の位置のみ返す。
    pub fn poll_gain(&mut self) -> Option<f32> {
        let mut latest_raw = None;
        for event in self.input.poll_events() {
            if let Some(raw) = self.state.apply(&event) {
                latest_raw = Some(raw);
            }
        }
        latest_raw.map(raw_to_gain)
    }

    /// ゲインをモーターフェーダー位置に反映する
    ///
    /// タッチ中は抑制する（ユーザー操作が優先。離したあとに呼べばスナップする）。
    pub fn project_gain(&mut self, gain: f32) -> WaveResult<()> {
        if self.state.touched() {
            return Ok(());
        }
        let msg = main_fader_message(gain_to_raw(gain));
        self.output
            .send(&msg)
            .map_err(|e| WaveError::Midi(format!("X-Touch send failed: {}", e)))
    }

    /// フェーダーがタッチされているか
    pub fn is_touched(&self) -> bool {
        self.state.touched()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_gain_roundtrip() {
        assert_eq!(gain_to_raw(0.0), 0);
        assert_eq!(gain_to_raw(1.0), FADER_MAX);
        assert!((raw_to_gain(FADER_MAX) - 1.0).abs() < f32::EPSILON);
        assert!((raw_to_gain(gain_to_raw(0.5)) - 0.5).abs() < 0.001);
        // 範囲外はクランプ
        assert_eq!(gain_to_raw(2.0), FADER_MAX);
        assert_eq!(gain_to_raw(-1.0), 0);
    }

    #[test]
    fn fader_message_is_pitch_bend_ch9() {
        // 最大値: status 0xE8、14bit を LSB/MSB に分割
        assert_eq!(main_fader_message(16383), [0xE8, 0x7F, 0x7F]);
        assert_eq!(main_fader_message(0), [0xE8, 0x00, 0x00]);
        // 8192 (center) = LSB 0x00, MSB 0x40
        assert_eq!(main_fader_message(8192), [0xE8, 0x00, 0x40]);
    }

    #[test]
    fn state_tracks_fader_moves_on_main_channel_only() {
        let mut state = MainFaderState::default();

        // Main チャンネルのフェーダー移動
        let moved = state.apply(&MidiEvent::PitchBend {
            channel: MAIN_FADER_CHANNEL,
            value: 8192,
        });
        assert_eq!(moved, Some(8192));

        // 別チャンネル（ストリップフェーダー等）は無視
        let other = state.apply(&MidiEvent::PitchBend {
            channel: 0,
            value: 100,
        });
        assert_eq!(other, None);
    }

    #[test]
    fn state_tracks_touch_via_note_0x70() {
        let mut state = MainFaderState::default();
        assert!(!state.touched());

        state.apply(&MidiEvent::NoteOn {
            channel: 0,
            note: MAIN_FADER_TOUCH_NOTE,
            velocity: 0x7F,
        });
        assert!(state.touched());

        // velocity 0 の NoteOn = 離した
        state.apply(&MidiEvent::NoteOn {
            channel: 0,
            note: MAIN_FADER_TOUCH_NOTE,
            velocity: 0,
        });
        assert!(!state.touched());

        // NoteOff でも離した扱い
        state.apply(&MidiEvent::NoteOn {
            channel: 0,
            note: MAIN_FADER_TOUCH_NOTE,
            velocity: 0x7F,
        });
        state.apply(&MidiEvent::NoteOff {
            channel: 0,
            note: MAIN_FADER_TOUCH_NOTE,
            velocity: 0,
        });
        assert!(!state.touched());

        // 他の note のタッチは無関係
        state.apply(&MidiEvent::NoteOn {
            channel: 0,
            note: 0x68,
            velocity: 0x7F,
        });
        assert!(!state.touched());
    }
}
