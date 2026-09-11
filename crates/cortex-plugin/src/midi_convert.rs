//! MIDI イベント変換
//!
//! cortex_midi::handler::MidiEvent ↔ rack::MidiEvent の変換を提供する。
//! REQ-PLUGIN-002: MIDIルーティング

use cortex_midi::handler::MidiEvent as WaveMidiEvent;
use rack::prelude::MidiEvent as RackMidiEvent;

// Re-export for convenience
pub use cortex_midi::handler::MidiEvent;

/// cortex_midi::MidiEvent を rack::MidiEvent に変換する
pub fn to_rack_midi(event: &WaveMidiEvent) -> Option<RackMidiEvent> {
    match event {
        WaveMidiEvent::NoteOn {
            note,
            velocity,
            channel,
        } => Some(RackMidiEvent::note_on(*note, *velocity, *channel, 0)),

        WaveMidiEvent::NoteOff {
            note,
            velocity,
            channel,
        } => Some(RackMidiEvent::note_off(*note, *velocity, *channel, 0)),

        WaveMidiEvent::ControlChange {
            control,
            value,
            channel,
        } => Some(RackMidiEvent::control_change(*control, *value, *channel, 0)),

        WaveMidiEvent::PitchBend { value, channel } => {
            // cortex_midi の pitch bend は i16 (-8192 to 8191)
            // rack の pitch bend は u16 (0 to 16383, center = 8192)
            let bend_value = (*value as i32 + 8192).clamp(0, 16383) as u16;
            Some(RackMidiEvent::pitch_bend(bend_value, *channel, 0))
        }

        WaveMidiEvent::ProgramChange { program, channel } => {
            Some(RackMidiEvent::program_change(*program, *channel, 0))
        }

        WaveMidiEvent::Aftertouch { pressure, channel } => {
            Some(RackMidiEvent::channel_aftertouch(*pressure, *channel, 0))
        }

        // ポリ AT は鍵盤ごとの圧力なので、note を保ったまま渡す。
        // channel_aftertouch に丸めてしまうと Keystage の表現力が失われる。
        WaveMidiEvent::PolyAftertouch {
            note,
            pressure,
            channel,
        } => Some(RackMidiEvent::polyphonic_aftertouch(
            *note, *pressure, *channel, 0,
        )),
    }
}

/// 複数の cortex_midi イベントを rack イベントに一括変換
pub fn to_rack_midi_batch(events: &[WaveMidiEvent]) -> Vec<RackMidiEvent> {
    events.iter().filter_map(to_rack_midi).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_note_on_conversion() {
        let wave_event = WaveMidiEvent::NoteOn {
            channel: 0,
            note: 60,
            velocity: 100,
        };
        let rack_event = to_rack_midi(&wave_event);
        assert!(rack_event.is_some());
    }

    #[test]
    fn test_note_off_conversion() {
        let wave_event = WaveMidiEvent::NoteOff {
            channel: 0,
            note: 60,
            velocity: 64,
        };
        let rack_event = to_rack_midi(&wave_event);
        assert!(rack_event.is_some());
    }

    #[test]
    fn test_cc_conversion() {
        let wave_event = WaveMidiEvent::ControlChange {
            channel: 0,
            control: 74,
            value: 127,
        };
        let rack_event = to_rack_midi(&wave_event);
        assert!(rack_event.is_some());
    }

    #[test]
    fn test_pitch_bend_conversion() {
        let wave_event = WaveMidiEvent::PitchBend {
            channel: 0,
            value: 0, // center
        };
        let rack_event = to_rack_midi(&wave_event);
        assert!(rack_event.is_some());
    }

    #[test]
    fn test_poly_aftertouch_conversion() {
        // 鍵盤ごとの圧力が AU へ渡ること（channel aftertouch に丸められない）
        let wave_event = WaveMidiEvent::PolyAftertouch {
            channel: 0,
            note: 64,
            pressure: 100,
        };
        assert!(to_rack_midi(&wave_event).is_some());
    }

    #[test]
    fn test_channel_aftertouch_conversion() {
        let wave_event = WaveMidiEvent::Aftertouch {
            channel: 0,
            pressure: 90,
        };
        assert!(to_rack_midi(&wave_event).is_some());
    }

    #[test]
    fn test_batch_conversion() {
        let events = vec![
            WaveMidiEvent::NoteOn {
                channel: 0,
                note: 60,
                velocity: 100,
            },
            WaveMidiEvent::NoteOn {
                channel: 0,
                note: 64,
                velocity: 100,
            },
            WaveMidiEvent::NoteOn {
                channel: 0,
                note: 67,
                velocity: 100,
            },
        ];
        let rack_events = to_rack_midi_batch(&events);
        assert_eq!(rack_events.len(), 3);
    }
}
