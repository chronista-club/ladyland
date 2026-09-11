//! MIDIメッセージハンドラー
//!
//! MIDIイベントを受信してパラメータに変換します。
//! REQ-MIDI-001: MIDI入力処理

use crossbeam_channel::{bounded, Receiver, Sender};
use midir::{MidiInput, MidiInputConnection, MidiOutput};
use midi_msg::{ChannelVoiceMsg, ControlChange, MidiMsg};

use cortex_types::{WaveError, WaveResult};

/// MIDIイベント
#[derive(Debug, Clone)]
pub enum MidiEvent {
    /// ノートオン
    NoteOn { channel: u8, note: u8, velocity: u8 },
    /// ノートオフ
    NoteOff { channel: u8, note: u8, velocity: u8 },
    /// コントロールチェンジ
    ControlChange { channel: u8, control: u8, value: u8 },
    /// ピッチベンド
    PitchBend { channel: u8, value: i16 },
    /// プログラムチェンジ
    ProgramChange { channel: u8, program: u8 },
    /// チャンネルアフタータッチ（鍵盤全体に一つの圧力）
    Aftertouch { channel: u8, pressure: u8 },
    /// ポリフォニック・アフタータッチ（押した鍵盤ごとの圧力）
    ///
    /// Keystage の看板機能。和音を押さえたまま一音だけ表情を変えられるため、
    /// チャンネルアフタータッチとは表現力が根本的に違う。混同しないこと。
    PolyAftertouch {
        channel: u8,
        note: u8,
        pressure: u8,
    },
}

/// `midi_msg` の `ControlChange` を `(CC番号, 7bit値)` に戻す。
///
/// midi_msg は既知の CC を名前付きバリアントへ畳み込む（CC0 → `BankSelect` 等）。
/// ここで取りこぼすとハードウェアのノブが**無言で効かなくなる**ため、
/// `_` で受けずに全バリアントを網羅する。バリアントが増えたらコンパイルエラーで気付ける。
///
/// 14bit 値を持つバリアントは MSB(7bit) に戻す。
fn control_to_cc(control: &ControlChange) -> Option<(u8, u8)> {
    // 14bit (MSB << 7) を 7bit に戻す
    let msb = |v: u16| (v >> 7) as u8;
    // スイッチ系は 0/127 に正規化
    let sw = |b: bool| if b { 127u8 } else { 0u8 };

    let pair = match *control {
        // --- 14bit 系 ---
        ControlChange::BankSelect(v) => (0, msb(v)),
        ControlChange::ModWheel(v) => (1, msb(v)),
        ControlChange::Breath(v) => (2, msb(v)),
        ControlChange::Foot(v) => (4, msb(v)),
        ControlChange::Portamento(v) => (5, msb(v)),
        ControlChange::DataEntry(v) => (6, msb(v)),
        ControlChange::Volume(v) => (7, msb(v)),
        ControlChange::Balance(v) => (8, msb(v)),
        ControlChange::Pan(v) => (10, msb(v)),
        ControlChange::Expression(v) => (11, msb(v)),
        ControlChange::Effect1(v) => (12, msb(v)),
        ControlChange::Effect2(v) => (13, msb(v)),
        ControlChange::GeneralPurpose1(v) => (16, msb(v)),
        ControlChange::GeneralPurpose2(v) => (17, msb(v)),
        ControlChange::GeneralPurpose3(v) => (18, msb(v)),
        ControlChange::GeneralPurpose4(v) => (19, msb(v)),
        // CC 3/9/14/15/20-31（未定義帯。ParamBridge が使う）
        ControlChange::UndefinedHighRes {
            control1, value, ..
        } => (control1, msb(value)),

        // --- 7bit 系: ペダル・スイッチ ---
        ControlChange::Hold(v) => (64, v),
        ControlChange::TogglePortamento(b) => (65, sw(b)),
        ControlChange::Sostenuto(v) => (66, v),
        ControlChange::SoftPedal(v) => (67, v),
        ControlChange::ToggleLegato(b) => (68, sw(b)),
        ControlChange::Hold2(v) => (69, v),

        // --- 7bit 系: サウンドコントローラ CC70-79 ---
        // midi_msg は同じ CC に別名バリアントを持つ（SoundControl1 = SoundVariation 等）
        ControlChange::SoundControl1(v) | ControlChange::SoundVariation(v) => (70, v),
        ControlChange::SoundControl2(v) | ControlChange::Timbre(v) => (71, v),
        ControlChange::SoundControl3(v) | ControlChange::ReleaseTime(v) => (72, v),
        ControlChange::SoundControl4(v) | ControlChange::AttackTime(v) => (73, v),
        ControlChange::SoundControl5(v) | ControlChange::Brightness(v) => (74, v),
        ControlChange::SoundControl6(v) | ControlChange::DecayTime(v) => (75, v),
        ControlChange::SoundControl7(v) | ControlChange::VibratoRate(v) => (76, v),
        ControlChange::SoundControl8(v) | ControlChange::VibratoDepth(v) => (77, v),
        ControlChange::SoundControl9(v) | ControlChange::VibratoDelay(v) => (78, v),
        ControlChange::SoundControl10(v) => (79, v),

        // --- 7bit 系: 汎用 CC80-83 / その他 ---
        ControlChange::GeneralPurpose5(v) => (80, v),
        ControlChange::GeneralPurpose6(v) => (81, v),
        ControlChange::GeneralPurpose7(v) => (82, v),
        ControlChange::GeneralPurpose8(v) => (83, v),
        ControlChange::PortamentoControl(v) => (84, v),
        ControlChange::HighResVelocity(v) => (88, v),

        // --- 7bit 系: エフェクト深度 CC91-95（別名あり） ---
        ControlChange::Effects1Depth(v) | ControlChange::ReverbSendLevel(v) => (91, v),
        ControlChange::Effects2Depth(v) | ControlChange::TremoloDepth(v) => (92, v),
        ControlChange::Effects3Depth(v) | ControlChange::ChorusSendLevel(v) => (93, v),
        ControlChange::Effects4Depth(v) | ControlChange::CelesteDepth(v) => (94, v),
        ControlChange::Effects5Depth(v) | ControlChange::PhaserDepth(v) => (95, v),

        ControlChange::DataIncrement(v) => (96, v),
        ControlChange::DataDecrement(v) => (97, v),
        // DataEntry の MSB/LSB ペア。MSB のみ CC6 として扱う
        ControlChange::DataEntry2(msb_v, _lsb) => (6, msb_v),

        // その他すべて（CC 9/14/15 等の生値を含む）
        ControlChange::Undefined { control, value } => (control, value),

        // NRPN/RPN は CC 98-101 のシーケンスで表現される別系統のため、
        // 単発の CC としては扱わない（必要になったら専用イベントを起こす）
        ControlChange::Parameter(_) => return None,
    };

    Some(pair)
}

/// MIDIハンドラー
pub struct MidiHandler {
    connection: Option<MidiInputConnection<()>>,
    event_receiver: Receiver<MidiEvent>,
    event_sender: Sender<MidiEvent>,
}

impl MidiHandler {
    /// 新しいハンドラーを作成
    pub fn new() -> WaveResult<Self> {
        let (tx, rx) = bounded(256);
        Ok(Self {
            connection: None,
            event_receiver: rx,
            event_sender: tx,
        })
    }

    /// 利用可能なMIDIポートを一覧取得
    pub fn list_ports() -> WaveResult<Vec<String>> {
        let midi_in = MidiInput::new("wave-generator")
            .map_err(|e| WaveError::Midi(format!("Failed to create MIDI input: {}", e)))?;

        let ports = midi_in.ports();
        let mut names = Vec::with_capacity(ports.len());

        for port in ports.iter() {
            if let Ok(name) = midi_in.port_name(port) {
                names.push(name);
            }
        }

        Ok(names)
    }

    /// 利用可能なMIDI出力ポートを一覧取得
    ///
    /// モーターフェーダーやLED付きコントローラー（ROTO / X-Touch 等）は
    /// 状態を送り返すために出力ポートを使うため、点検対象に含める。
    pub fn list_output_ports() -> WaveResult<Vec<String>> {
        let midi_out = MidiOutput::new("wave-generator")
            .map_err(|e| WaveError::Midi(format!("Failed to create MIDI output: {}", e)))?;

        let ports = midi_out.ports();
        let mut names = Vec::with_capacity(ports.len());

        for port in ports.iter() {
            if let Ok(name) = midi_out.port_name(port) {
                names.push(name);
            }
        }

        Ok(names)
    }

    /// 指定したポート名に接続
    pub fn connect(&mut self, port_name: &str) -> WaveResult<()> {
        let midi_in = MidiInput::new("wave-generator")
            .map_err(|e| WaveError::Midi(format!("Failed to create MIDI input: {}", e)))?;

        let ports = midi_in.ports();
        let port = ports
            .iter()
            .find(|p| {
                midi_in
                    .port_name(p)
                    .map(|n| n.contains(port_name))
                    .unwrap_or(false)
            })
            .ok_or_else(|| WaveError::Midi(format!("Port not found: {}", port_name)))?
            .clone();

        let port_name_full = midi_in
            .port_name(&port)
            .unwrap_or_else(|_| "Unknown".into());

        let tx = self.event_sender.clone();

        let connection = midi_in
            .connect(
                &port,
                "wave-generator-input",
                move |_timestamp, message, _| {
                    if let Some(event) = Self::parse_message(message) {
                        let _ = tx.try_send(event);
                    }
                },
                (),
            )
            .map_err(|e| WaveError::Midi(format!("Failed to connect: {}", e)))?;

        self.connection = Some(connection);
        tracing::info!("Connected to MIDI port: {}", port_name_full);

        Ok(())
    }

    /// Korg Keystageを自動検出して接続
    pub fn connect_keystage(&mut self) -> WaveResult<()> {
        let ports = Self::list_ports()?;

        // Keystageを探す
        if let Some(port_name) = ports.iter().find(|p| {
            p.to_lowercase().contains("keystage")
                || p.to_lowercase().contains("korg")
        }) {
            return self.connect(port_name);
        }

        // 見つからない場合は最初のポートに接続
        if let Some(port_name) = ports.first() {
            tracing::warn!("Keystage not found, connecting to: {}", port_name);
            return self.connect(port_name);
        }

        Err(WaveError::Midi("No MIDI devices found".into()))
    }

    /// MIDIメッセージをパース
    fn parse_message(data: &[u8]) -> Option<MidiEvent> {
        let (msg, _) = MidiMsg::from_midi(data).ok()?;

        match msg {
            MidiMsg::ChannelVoice { channel, msg } => {
                // channel を u8 に変換（0-15）
                let ch = channel as u8;
                match msg {
                    ChannelVoiceMsg::NoteOn { note, velocity } => Some(MidiEvent::NoteOn {
                        channel: ch,
                        note,
                        velocity,
                    }),
                    ChannelVoiceMsg::NoteOff { note, velocity } => Some(MidiEvent::NoteOff {
                        channel: ch,
                        note,
                        velocity,
                    }),
                    ChannelVoiceMsg::ControlChange { control } => {
                        let (cc_num, cc_val) = control_to_cc(&control)?;
                        Some(MidiEvent::ControlChange {
                            channel: ch,
                            control: cc_num,
                            value: cc_val,
                        })
                    }
                    ChannelVoiceMsg::PitchBend { bend } => Some(MidiEvent::PitchBend {
                        channel: ch,
                        value: bend as i16,
                    }),
                    ChannelVoiceMsg::ProgramChange { program } => Some(MidiEvent::ProgramChange {
                        channel: ch,
                        program,
                    }),
                    ChannelVoiceMsg::ChannelPressure { pressure } => Some(MidiEvent::Aftertouch {
                        channel: ch,
                        pressure,
                    }),
                    ChannelVoiceMsg::PolyPressure { note, pressure } => {
                        Some(MidiEvent::PolyAftertouch {
                            channel: ch,
                            note,
                            pressure,
                        })
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// 保留中のイベントを取得
    pub fn poll_events(&self) -> Vec<MidiEvent> {
        let mut events = Vec::new();
        while let Ok(event) = self.event_receiver.try_recv() {
            events.push(event);
        }
        events
    }

    /// イベントレシーバーを取得
    pub fn event_receiver(&self) -> Receiver<MidiEvent> {
        self.event_receiver.clone()
    }

    /// 接続中かどうか
    pub fn is_connected(&self) -> bool {
        self.connection.is_some()
    }

    /// 切断
    pub fn disconnect(&mut self) {
        if let Some(connection) = self.connection.take() {
            connection.close();
            tracing::info!("MIDI disconnected");
        }
    }
}

impl Drop for MidiHandler {
    fn drop(&mut self) {
        self.disconnect();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 生の CC メッセージ（channel 0）をパースする
    fn parse_cc(cc: u8, value: u8) -> Option<(u8, u8)> {
        match MidiHandler::parse_message(&[0xB0, cc, value]) {
            Some(MidiEvent::ControlChange { control, value, .. }) => Some((control, value)),
            _ => None,
        }
    }

    /// スイッチ扱いの CC（0/127 に正規化されるため値は素通ししない）
    const SWITCH_CCS: [u8; 2] = [65, 68];

    #[test]
    fn no_cc_is_silently_dropped() {
        // ハードウェアのノブが無言で効かなくなる事故を防ぐ不変条件。
        // CC 0-119 は必ず同じ CC 番号のイベントとして届くこと。
        for cc in 0u8..=119 {
            let parsed = parse_cc(cc, 64);
            assert!(parsed.is_some(), "CC {} が破棄された", cc);
            let (num, val) = parsed.unwrap();
            assert_eq!(num, cc, "CC {} が別番号 {} になった", cc, num);
            if !SWITCH_CCS.contains(&cc) {
                assert_eq!(val, 64, "CC {} の値が変化した", cc);
            }
        }
    }

    #[test]
    fn previously_dropped_ccs_now_pass() {
        // 修正前に midi_msg の名前付きバリアントへ畳まれて破棄されていたもの
        assert_eq!(parse_cc(0, 100), Some((0, 100))); // BankSelect（回転速度に使用）
        assert_eq!(parse_cc(5, 42), Some((5, 42))); // Portamento（LPD8 K5）
        assert_eq!(parse_cc(6, 42), Some((6, 42))); // DataEntry（LPD8 K6）
        assert_eq!(parse_cc(16, 1), Some((16, 1))); // GeneralPurpose1（custom_params）
        assert_eq!(parse_cc(19, 127), Some((19, 127))); // GeneralPurpose4
        assert_eq!(parse_cc(70, 55), Some((70, 55))); // SoundControl1
        assert_eq!(parse_cc(79, 55), Some((79, 55))); // SoundControl10
        assert_eq!(parse_cc(91, 55), Some((91, 55))); // Effects1Depth
    }

    #[test]
    fn existing_ccs_still_work() {
        assert_eq!(parse_cc(1, 64), Some((1, 64))); // ModWheel
        assert_eq!(parse_cc(7, 64), Some((7, 64))); // Volume
        assert_eq!(parse_cc(20, 64), Some((20, 64))); // ParamBridge 帯（14bit）
        assert_eq!(parse_cc(64, 127), Some((64, 127))); // Hold
    }

    #[test]
    fn switch_ccs_normalize_to_0_or_127() {
        assert_eq!(parse_cc(65, 127), Some((65, 127))); // TogglePortamento on
        assert_eq!(parse_cc(65, 0), Some((65, 0))); // off
        assert_eq!(parse_cc(68, 127), Some((68, 127))); // ToggleLegato on
    }

    #[test]
    fn poly_aftertouch_keeps_note_identity() {
        // Keystage の看板機能。鍵盤ごとの圧力が note を保って届くこと。
        // status 0xA0 = PolyPressure
        assert!(matches!(
            MidiHandler::parse_message(&[0xA0, 64, 100]),
            Some(MidiEvent::PolyAftertouch {
                note: 64,
                pressure: 100,
                channel: 0,
            })
        ));
        // 別の鍵盤は別イベントとして区別される（和音中の一音だけの表情）
        assert!(matches!(
            MidiHandler::parse_message(&[0xA0, 67, 20]),
            Some(MidiEvent::PolyAftertouch {
                note: 67,
                pressure: 20,
                ..
            })
        ));
    }

    #[test]
    fn channel_aftertouch_is_distinct_from_poly() {
        // 0xD0 = ChannelPressure（鍵盤全体）。ポリ AT と混同しないこと。
        assert!(matches!(
            MidiHandler::parse_message(&[0xD0, 90, 0]),
            Some(MidiEvent::Aftertouch { pressure: 90, .. })
        ));
    }

    #[test]
    fn note_and_pitch_bend_parse() {
        assert!(matches!(
            MidiHandler::parse_message(&[0x90, 60, 100]),
            Some(MidiEvent::NoteOn {
                note: 60,
                velocity: 100,
                ..
            })
        ));
        assert!(matches!(
            MidiHandler::parse_message(&[0x80, 60, 0]),
            Some(MidiEvent::NoteOff { note: 60, .. })
        ));
        assert!(matches!(
            MidiHandler::parse_message(&[0xE0, 0x00, 0x40]),
            Some(MidiEvent::PitchBend { .. })
        ));
    }
}
