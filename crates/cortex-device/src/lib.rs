//! wave-maru: MARU デバイス連携
//!
//! ESP32-S3 ベースの物理コントローラー「MARU」と TCP で通信し、
//! macOS のシステム音量制御などを提供する。
//!
//! ## Wire Protocol
//! ```text
//! [0x4D][MsgType:u8][PayLen:u16BE][Payload]
//! ```

pub mod protocol;
pub mod server;
pub mod volume;

pub use protocol::{DeviceMessage, HostMessage, ModeId};
pub use server::MaruServer;
