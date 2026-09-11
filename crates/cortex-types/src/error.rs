//! エラー型定義
//!
//! REQ-CORE-003: 統一エラー型

use thiserror::Error;

/// wave-generatorのエラー型
#[derive(Error, Debug)]
pub enum WaveError {
    /// オーディオエラー
    #[error("Audio error: {0}")]
    Audio(String),

    /// デコードエラー
    #[error("Decode error: {0}")]
    Decode(String),

    /// グラフィックスエラー
    #[error("Graphics error: {0}")]
    Graphics(String),

    /// MIDIエラー
    #[error("MIDI error: {0}")]
    Midi(String),

    /// エンコードエラー
    #[error("Encode error: {0}")]
    Encode(String),

    /// プリセットエラー
    #[error("Preset error: {0}")]
    Preset(String),

    /// ファイルI/Oエラー
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    /// プラグインエラー
    #[error("Plugin error: {0}")]
    Plugin(String),

    /// 設定エラー
    #[error("Config error: {0}")]
    Config(String),

    /// チャンネルエラー（スレッド間通信）
    #[error("Channel error: {0}")]
    Channel(String),
}

/// Result型エイリアス
pub type WaveResult<T> = Result<T, WaveError>;
