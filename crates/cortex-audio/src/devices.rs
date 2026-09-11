//! オーディオデバイスの列挙
//!
//! 接続されているオーディオI/Oを一覧し、対応チャンネル数・サンプルレートを取得する。
//!
//! 用途は2つ:
//! - **本番前のリグ点検**（`rigcheck`）— 機材が想定通り認識されているかの確認
//! - **出力デバイスの明示選択** — 既定デバイス任せにせず、名前で対象を選ぶ

use cpal::traits::{DeviceTrait, HostTrait};

use cortex_types::{WaveError, WaveResult};

/// 対応するストリーム設定の範囲
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupportedRange {
    /// チャンネル数
    pub channels: u16,
    /// 最小サンプルレート (Hz)
    pub min_sample_rate: u32,
    /// 最大サンプルレート (Hz)
    pub max_sample_rate: u32,
    /// サンプルフォーマット（"f32" 等）
    pub sample_format: String,
}

/// オーディオデバイス情報
#[derive(Debug, Clone)]
pub struct AudioDeviceInfo {
    /// デバイス名
    pub name: String,
    /// OS の既定デバイスか
    pub is_default: bool,
    /// 既定設定 (チャンネル数, サンプルレート)
    pub default_config: Option<(u16, u32)>,
    /// 対応する設定範囲の一覧
    pub supported: Vec<SupportedRange>,
}

impl AudioDeviceInfo {
    /// このデバイスが出せる最大チャンネル数
    ///
    /// ミキサーへ何系統送れるかの判断材料。2 ならステレオ1系統のみ。
    pub fn max_channels(&self) -> u16 {
        self.supported
            .iter()
            .map(|r| r.channels)
            .max()
            .or(self.default_config.map(|(ch, _)| ch))
            .unwrap_or(0)
    }
}

/// 入出力の向き
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// 再生（Mac → 機材）
    Output,
    /// 録音（機材 → Mac）
    Input,
}

/// 指定方向のオーディオデバイスを列挙する
pub fn list_devices(direction: Direction) -> WaveResult<Vec<AudioDeviceInfo>> {
    let host = cpal::default_host();

    let default_name = match direction {
        Direction::Output => host.default_output_device(),
        Direction::Input => host.default_input_device(),
    }
    .and_then(|d| d.name().ok());

    let devices = match direction {
        Direction::Output => host.output_devices().map_err(|e| {
            WaveError::Audio(format!("Failed to enumerate output devices: {}", e))
        })?,
        Direction::Input => host
            .input_devices()
            .map_err(|e| WaveError::Audio(format!("Failed to enumerate input devices: {}", e)))?,
    };

    let mut result = Vec::new();
    for device in devices {
        let name = device.name().unwrap_or_else(|_| "<unknown>".to_string());

        let default_config = match direction {
            Direction::Output => device.default_output_config().ok(),
            Direction::Input => device.default_input_config().ok(),
        }
        .map(|c| (c.channels(), c.sample_rate().0));

        let configs = match direction {
            Direction::Output => device
                .supported_output_configs()
                .map(|it| it.collect::<Vec<_>>()),
            Direction::Input => device
                .supported_input_configs()
                .map(|it| it.collect::<Vec<_>>()),
        };

        let supported = configs
            .map(|ranges| {
                ranges
                    .into_iter()
                    .map(|r| SupportedRange {
                        channels: r.channels(),
                        min_sample_rate: r.min_sample_rate().0,
                        max_sample_rate: r.max_sample_rate().0,
                        sample_format: format!("{}", r.sample_format()),
                    })
                    .collect()
            })
            .unwrap_or_default();

        result.push(AudioDeviceInfo {
            is_default: default_name.as_deref() == Some(name.as_str()),
            name,
            default_config,
            supported,
        });
    }

    Ok(result)
}

/// 名前の部分一致でデバイスを探す（大文字小文字を無視）
///
/// 既定デバイス任せにせず対象を固定するために使う。
/// ライブ中に OS の既定出力が変わっても影響を受けないようにするのが狙い。
pub fn find_device(direction: Direction, name_pattern: &str) -> WaveResult<Option<AudioDeviceInfo>> {
    let pattern = name_pattern.to_lowercase();
    Ok(list_devices(direction)?
        .into_iter()
        .find(|d| d.name.to_lowercase().contains(&pattern)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_channels_prefers_supported_range() {
        let info = AudioDeviceInfo {
            name: "Test".into(),
            is_default: false,
            default_config: Some((2, 48000)),
            supported: vec![
                SupportedRange {
                    channels: 2,
                    min_sample_rate: 44100,
                    max_sample_rate: 48000,
                    sample_format: "f32".into(),
                },
                SupportedRange {
                    channels: 8,
                    min_sample_rate: 48000,
                    max_sample_rate: 96000,
                    sample_format: "f32".into(),
                },
            ],
        };
        assert_eq!(info.max_channels(), 8);
    }

    #[test]
    fn max_channels_falls_back_to_default_config() {
        let info = AudioDeviceInfo {
            name: "Test".into(),
            is_default: true,
            default_config: Some((2, 48000)),
            supported: vec![],
        };
        assert_eq!(info.max_channels(), 2);
    }

    #[test]
    fn max_channels_is_zero_when_unknown() {
        let info = AudioDeviceInfo {
            name: "Test".into(),
            is_default: false,
            default_config: None,
            supported: vec![],
        };
        assert_eq!(info.max_channels(), 0);
    }
}
