//! MIDIコントローラー
//!
//! MIDIイベントをシェーダーパラメータにマッピングします。
//! REQ-MIDI-002: パラメータマッピング

use cortex_gpu::ShaderUniforms;

use crate::handler::MidiEvent;

/// MIDIコントローラー
///
/// MIDIイベントを処理してShaderUniformsに反映します。
pub struct MidiController {
    /// 現在のCC値 (0-127を0.0-1.0に正規化)
    cc_values: [f32; 128],
    /// ピッチベンド (-1.0 to 1.0)
    pitch_bend: f32,
    /// モジュレーションホイール (CC 1)
    mod_wheel: f32,
    /// 現在のシーン
    current_scene: usize,
    /// 最後にノートオンされたノート
    last_note: Option<u8>,
    /// ノートベロシティ
    note_velocity: f32,
}

impl MidiController {
    /// 新しいコントローラーを作成
    pub fn new() -> Self {
        Self {
            cc_values: [0.0; 128],
            pitch_bend: 0.0,
            mod_wheel: 0.0,
            current_scene: 0,
            last_note: None,
            note_velocity: 0.0,
        }
    }

    /// MIDIイベントを処理
    pub fn process_event(&mut self, event: &MidiEvent) {
        match event {
            MidiEvent::NoteOn { note, velocity, .. } => {
                self.last_note = Some(*note);
                self.note_velocity = *velocity as f32 / 127.0;

                // ノート60-67でシーン切り替え
                if *note >= 60 && *note < 68 {
                    self.current_scene = (*note - 60) as usize;
                    tracing::info!("Scene changed to: {}", self.current_scene);
                }
            }
            MidiEvent::NoteOff { note, .. } => {
                if self.last_note == Some(*note) {
                    self.note_velocity = 0.0;
                }
            }
            MidiEvent::ControlChange { control, value, .. } => {
                let normalized = *value as f32 / 127.0;
                self.cc_values[*control as usize] = normalized;

                // CC 1 = モジュレーションホイール
                if *control == 1 {
                    self.mod_wheel = normalized;
                }

                tracing::debug!("CC {}: {:.2}", control, normalized);
            }
            MidiEvent::PitchBend { value, .. } => {
                // -8192 to 8191 を -1.0 to 1.0 に変換
                self.pitch_bend = *value as f32 / 8192.0;
            }
            MidiEvent::ProgramChange { program, .. } => {
                if *program < 8 {
                    self.current_scene = *program as usize;
                    tracing::info!("Scene changed via PC to: {}", self.current_scene);
                }
            }
            _ => {}
        }
    }

    /// 複数のイベントを処理
    pub fn process_events(&mut self, events: &[MidiEvent]) {
        for event in events {
            self.process_event(event);
        }
    }

    /// ShaderUniformsにMIDI値を適用
    pub fn apply_to_uniforms(&self, uniforms: &mut ShaderUniforms) {
        // CC 0-7をmidi_ccにマッピング
        for i in 0..8 {
            uniforms.midi_cc[i] = self.cc_values[i];
        }

        uniforms.midi_pitch_bend = self.pitch_bend;
        uniforms.midi_mod_wheel = self.mod_wheel;
        uniforms.scene_index = self.current_scene as f32;

        // カスタムパラメータ
        // CC 16-19をcustom_paramsにマッピング
        for i in 0..4 {
            uniforms.custom_params[i] = self.cc_values[16 + i];
        }
    }

    /// CC値を取得
    pub fn get_cc(&self, cc: u8) -> f32 {
        self.cc_values[cc as usize]
    }

    /// 現在のシーンを取得
    pub fn current_scene(&self) -> usize {
        self.current_scene
    }

    /// ピッチベンド値を取得
    pub fn pitch_bend(&self) -> f32 {
        self.pitch_bend
    }

    /// モジュレーションホイール値を取得
    pub fn mod_wheel(&self) -> f32 {
        self.mod_wheel
    }

    /// 最後にノートオンされたノートを取得
    pub fn last_note(&self) -> Option<u8> {
        self.last_note
    }

    /// ノートベロシティを取得
    pub fn note_velocity(&self) -> f32 {
        self.note_velocity
    }

    /// リセット
    pub fn reset(&mut self) {
        self.cc_values = [0.0; 128];
        self.pitch_bend = 0.0;
        self.mod_wheel = 0.0;
        self.note_velocity = 0.0;
        self.last_note = None;
    }
}

impl Default for MidiController {
    fn default() -> Self {
        Self::new()
    }
}

/// CCマッピング定義
#[derive(Debug, Clone)]
pub struct CcMapping {
    /// CC番号
    pub cc: u8,
    /// パラメータ名
    pub name: String,
    /// 最小値
    pub min: f32,
    /// 最大値
    pub max: f32,
    /// デフォルト値
    pub default: f32,
}

impl CcMapping {
    /// 新しいマッピングを作成
    pub fn new(cc: u8, name: &str, min: f32, max: f32, default: f32) -> Self {
        Self {
            cc,
            name: name.to_string(),
            min,
            max,
            default,
        }
    }

    /// CC値を指定範囲にマッピング
    pub fn map_value(&self, normalized: f32) -> f32 {
        self.min + normalized * (self.max - self.min)
    }
}

/// Korg Keystage用のデフォルトマッピング
pub fn keystage_default_mappings() -> Vec<CcMapping> {
    vec![
        CcMapping::new(0, "Rotation Speed", 0.0, 2.0, 0.5),
        CcMapping::new(1, "Mod Wheel", 0.0, 1.0, 0.0),
        CcMapping::new(2, "Color Hue Offset", 0.0, 1.0, 0.0),
        CcMapping::new(3, "Glow Intensity", 0.0, 2.0, 1.0),
        CcMapping::new(4, "Ring Count", 1.0, 8.0, 4.0),
        CcMapping::new(5, "Zoom Level", 0.5, 2.0, 1.0),
        CcMapping::new(6, "Distortion", 0.0, 1.0, 0.0),
        CcMapping::new(7, "Brightness", 0.5, 1.5, 1.0),
    ]
}
