//! プラグインエラー型
//!
//! REQ-PLUGIN-001: プラグインホスティングエラー

use thiserror::Error;

/// プラグインエラー
#[derive(Error, Debug)]
pub enum PluginError {
    /// プラグインのロードに失敗
    #[error("Failed to load plugin: {0}")]
    Load(String),

    /// プラグインの初期化に失敗
    #[error("Failed to initialize plugin: {0}")]
    Initialize(String),

    /// オーディオ処理エラー
    #[error("Audio processing error: {0}")]
    Process(String),

    /// MIDIイベント送信エラー
    #[error("MIDI send error: {0}")]
    MidiSend(String),

    /// パラメータ操作エラー
    #[error("Parameter error: {0}")]
    Parameter(String),

    /// プラグインが見つからない
    #[error("Plugin not found: {0}")]
    NotFound(String),

    /// スキャナーエラー
    #[error("Scanner error: {0}")]
    Scanner(String),

    /// チャンネル通信エラー
    #[error("Channel error: {0}")]
    Channel(String),

    /// rack crateのエラー
    #[error("Rack error: {0}")]
    Rack(#[from] rack::Error),
}

/// Result型エイリアス
pub type PluginResult<T> = Result<T, PluginError>;
