//! wave-midi - MIDI input handling
//!
//! midirを使用してMIDI入力を処理します。
//!
//! ## 機能
//! - MIDIデバイス検出・接続
//! - MIDIメッセージのパース
//! - コントロールチェンジのマッピング
//! - シーン切り替え

pub mod controller;
pub mod handler;
pub mod hub;
pub mod xtouch;

pub use controller::MidiController;
pub use handler::MidiHandler;
pub use hub::{DeviceKind, HubEvent, MidiHub};
pub use xtouch::XTouchMainFader;
