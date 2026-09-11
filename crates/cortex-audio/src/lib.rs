//! wave-audio - Audio playback and analysis
//!
//! オーディオファイルのデコード、再生、FFT解析を提供します。
//!
//! ## 構成
//! - `player`: cpalベースのオーディオ再生
//! - `decoder`: symphoniaベースのオーディオデコード
//! - `analyzer`: FFTとビート検出
//! - `ringbuffer`: ロックフリーリングバッファ
//! - `devices`: オーディオI/Oの列挙・名前指定での検索

pub mod analyzer;
pub mod decoder;
pub mod devices;
pub mod player;
pub mod ringbuffer;

pub use analyzer::AudioAnalyzer;
pub use decoder::AudioDecoder;
pub use devices::{AudioDeviceInfo, Direction, SupportedRange};
pub use player::AudioPlayer;
pub use ringbuffer::RingBuffer;
