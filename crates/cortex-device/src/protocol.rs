//! MARU Wire Protocol
//!
//! バイナリフレーム構造:
//! ```text
//! +--------+--------+---------+---------+---...---+
//! | 0x4D   | MsgType| PayLen (u16 BE)   | Payload |
//! | (Magic)| u8     | u16               | [u8]    |
//! +--------+--------+---------+---------+---...---+
//! ```

use std::io::{self, Read, Write};

/// マジックバイト
const MAGIC: u8 = 0x4D;
/// フレームヘッダサイズ (magic + type + len)
const HEADER_SIZE: usize = 4;

/// モードID
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ModeId {
    Clock = 0x01,
    Volume = 0x02,
    Terminal = 0x03,
    CustomApp = 0x04,
    Bitwig = 0x05,
    WiFiInfo = 0x06,
}

impl ModeId {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0x01 => Some(Self::Clock),
            0x02 => Some(Self::Volume),
            0x03 => Some(Self::Terminal),
            0x04 => Some(Self::CustomApp),
            0x05 => Some(Self::Bitwig),
            0x06 => Some(Self::WiFiInfo),
            _ => None,
        }
    }
}

/// Device → PC メッセージ
#[derive(Debug, Clone)]
pub enum DeviceMessage {
    /// 接続時の挨拶 (fw_version, device_id MAC 6bytes)
    Hello {
        fw_version: u8,
        device_id: [u8; 6],
    },
    /// モード変更通知
    ModeChange {
        mode_id: u8,
    },
    /// ロータリーエンコーダー回転
    RotaryDelta {
        mode_id: u8,
        delta: i8,
    },
    /// ボタンアクション (action: 0=short, 1=long)
    ButtonAction {
        mode_id: u8,
        action: u8,
    },
    /// ハートビート
    Heartbeat {
        uptime_secs: u32,
    },
}

/// PC → Device メッセージ
#[derive(Debug, Clone)]
pub enum HostMessage {
    /// 接続応答
    Welcome,
    /// 状態更新
    StateUpdate {
        mode_id: u8,
        state_blob: Vec<u8>,
    },
    /// モード強制変更
    ForceMode {
        mode_id: u8,
    },
}

// --- パーサー ---

/// TCP ストリームから 1 フレームを読み出す
///
/// ブロッキング read。接続が切れたら Ok(None) を返す。
pub fn read_frame(reader: &mut impl Read) -> io::Result<Option<DeviceMessage>> {
    // ヘッダ読み取り
    let mut header = [0u8; HEADER_SIZE];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(ref e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    if header[0] != MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid magic byte: 0x{:02X}", header[0]),
        ));
    }

    let msg_type = header[1];
    let payload_len = u16::from_be_bytes([header[2], header[3]]) as usize;

    // ペイロード読み取り
    let mut payload = vec![0u8; payload_len];
    if payload_len > 0 {
        reader.read_exact(&mut payload)?;
    }

    parse_device_message(msg_type, &payload)
        .map(Some)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn parse_device_message(msg_type: u8, payload: &[u8]) -> Result<DeviceMessage, String> {
    match msg_type {
        // Hello
        0x01 => {
            if payload.len() < 7 {
                return Err("Hello payload too short".into());
            }
            let fw_version = payload[0];
            let mut device_id = [0u8; 6];
            device_id.copy_from_slice(&payload[1..7]);
            Ok(DeviceMessage::Hello {
                fw_version,
                device_id,
            })
        }
        // ModeChange
        0x02 => {
            if payload.is_empty() {
                return Err("ModeChange payload empty".into());
            }
            Ok(DeviceMessage::ModeChange {
                mode_id: payload[0],
            })
        }
        // RotaryDelta
        0x10 => {
            if payload.len() < 2 {
                return Err("RotaryDelta payload too short".into());
            }
            Ok(DeviceMessage::RotaryDelta {
                mode_id: payload[0],
                delta: payload[1] as i8,
            })
        }
        // ButtonAction
        0x11 => {
            if payload.len() < 2 {
                return Err("ButtonAction payload too short".into());
            }
            Ok(DeviceMessage::ButtonAction {
                mode_id: payload[0],
                action: payload[1],
            })
        }
        // Heartbeat
        0x12 => {
            if payload.len() < 4 {
                return Err("Heartbeat payload too short".into());
            }
            let uptime_secs = u32::from_be_bytes([
                payload[0],
                payload[1],
                payload[2],
                payload[3],
            ]);
            Ok(DeviceMessage::Heartbeat { uptime_secs })
        }
        _ => Err(format!("unknown message type: 0x{:02X}", msg_type)),
    }
}

// --- シリアライザー ---

/// HostMessage をバイト列にエンコードして書き込む
pub fn write_frame(writer: &mut impl Write, msg: &HostMessage) -> io::Result<()> {
    let (msg_type, payload) = encode_host_message(msg);
    let payload_len = payload.len() as u16;

    writer.write_all(&[MAGIC, msg_type])?;
    writer.write_all(&payload_len.to_be_bytes())?;
    writer.write_all(&payload)?;
    writer.flush()
}

fn encode_host_message(msg: &HostMessage) -> (u8, Vec<u8>) {
    match msg {
        HostMessage::Welcome => (0x80, Vec::new()),
        HostMessage::StateUpdate {
            mode_id,
            state_blob,
        } => {
            let mut payload = Vec::with_capacity(1 + state_blob.len());
            payload.push(*mode_id);
            payload.extend_from_slice(state_blob);
            (0x81, payload)
        }
        HostMessage::ForceMode { mode_id } => (0x82, vec![*mode_id]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_roundtrip_welcome() {
        let mut buf = Vec::new();
        write_frame(&mut buf, &HostMessage::Welcome).unwrap();
        assert_eq!(buf, vec![0x4D, 0x80, 0x00, 0x00]);
    }

    #[test]
    fn test_roundtrip_state_update() {
        let mut buf = Vec::new();
        let msg = HostMessage::StateUpdate {
            mode_id: ModeId::Volume as u8,
            state_blob: vec![72, 0, 7, b'S', b'p', b'e', b'a', b'k', b'e', b'r'],
        };
        write_frame(&mut buf, &msg).unwrap();
        // magic + type + len(2) + mode_id + blob
        assert_eq!(buf[0], 0x4D);
        assert_eq!(buf[1], 0x81);
    }

    #[test]
    fn test_parse_hello() {
        let payload = vec![
            0x4D, 0x01, 0x00, 0x07, // header: Hello, 7 bytes
            0x0D, // fw_version = 13
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // MAC
        ];
        let mut cursor = Cursor::new(payload);
        let msg = read_frame(&mut cursor).unwrap().unwrap();
        match msg {
            DeviceMessage::Hello {
                fw_version,
                device_id,
            } => {
                assert_eq!(fw_version, 13);
                assert_eq!(device_id, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
            }
            _ => panic!("expected Hello"),
        }
    }

    #[test]
    fn test_parse_rotary_delta() {
        let payload = vec![
            0x4D, 0x10, 0x00, 0x02, // header: RotaryDelta, 2 bytes
            0x02, // mode_id = Volume
            0xFE, // delta = -2 (as i8)
        ];
        let mut cursor = Cursor::new(payload);
        let msg = read_frame(&mut cursor).unwrap().unwrap();
        match msg {
            DeviceMessage::RotaryDelta { mode_id, delta } => {
                assert_eq!(mode_id, 0x02);
                assert_eq!(delta, -2);
            }
            _ => panic!("expected RotaryDelta"),
        }
    }

    #[test]
    fn test_parse_button_action() {
        let payload = vec![
            0x4D, 0x11, 0x00, 0x02, // header: ButtonAction, 2 bytes
            0x02, // mode_id = Volume
            0x00, // action = short press
        ];
        let mut cursor = Cursor::new(payload);
        let msg = read_frame(&mut cursor).unwrap().unwrap();
        match msg {
            DeviceMessage::ButtonAction { mode_id, action } => {
                assert_eq!(mode_id, 0x02);
                assert_eq!(action, 0);
            }
            _ => panic!("expected ButtonAction"),
        }
    }

    #[test]
    fn test_eof_returns_none() {
        let mut cursor = Cursor::new(Vec::<u8>::new());
        let result = read_frame(&mut cursor).unwrap();
        assert!(result.is_none());
    }
}
