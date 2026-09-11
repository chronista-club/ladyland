//! オーディオプレーヤー
//!
//! cpalを使用してオーディオを再生します。
//! REQ-AUDIO-002: オーディオ再生

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_channel::{bounded, Receiver, Sender};

use cortex_types::{AudioConfig, AudioFrame, WaveError, WaveResult};

/// オーディオプレーヤー
pub struct AudioPlayer {
    stream: Option<cpal::Stream>,
    config: AudioConfig,
    is_playing: Arc<AtomicBool>,
    position_samples: Arc<AtomicU64>,
    frame_sender: Option<Sender<AudioFrame>>,
    analysis_receiver: Option<Receiver<AudioFrame>>,
}

impl AudioPlayer {
    /// 新しいプレーヤーを作成
    pub fn new(config: AudioConfig) -> WaveResult<Self> {
        Ok(Self {
            stream: None,
            config,
            is_playing: Arc::new(AtomicBool::new(false)),
            position_samples: Arc::new(AtomicU64::new(0)),
            frame_sender: None,
            analysis_receiver: None,
        })
    }

    /// デフォルト設定でプレーヤーを作成
    pub fn with_defaults() -> WaveResult<Self> {
        Self::new(AudioConfig::default())
    }

    /// デフォルト出力デバイスのサンプルレートを取得する（ストリームは作成しない）
    ///
    /// プラグインホストなど、ストリーム初期化前に実デバイスのサンプルレートが
    /// 必要な場合に使う。
    pub fn default_output_sample_rate() -> WaveResult<u32> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| WaveError::Audio("No output device found".into()))?;
        let config = device
            .default_output_config()
            .map_err(|e| WaveError::Audio(format!("Failed to get config: {}", e)))?;
        Ok(config.sample_rate().0)
    }

    /// オーディオ出力ストリームを初期化
    pub fn initialize(&mut self) -> WaveResult<Receiver<AudioFrame>> {
        let (frame_tx, frame_rx) = bounded::<AudioFrame>(32);
        let analysis_rx = self.initialize_with_source(frame_rx)?;
        self.frame_sender = Some(frame_tx);
        Ok(analysis_rx)
    }

    /// 外部ソースからのフレームを使ってオーディオ出力ストリームを初期化
    ///
    /// プラグインスレッドの processed_rx 等、外部から渡された Receiver を
    /// cpal コールバックのソースとして使用する。
    /// この場合、frame_sender は None のまま（デコーダーは外部で管理）。
    pub fn initialize_with_source(
        &mut self,
        source_rx: Receiver<AudioFrame>,
    ) -> WaveResult<Receiver<AudioFrame>> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| WaveError::Audio("No output device found".into()))?;

        let supported_config = device
            .default_output_config()
            .map_err(|e| WaveError::Audio(format!("Failed to get config: {}", e)))?;

        let sample_rate = supported_config.sample_rate().0;
        let channels = supported_config.channels();

        self.config.sample_rate = sample_rate;
        self.config.channels = channels;

        tracing::info!(
            "Audio output: {} Hz, {} channels",
            sample_rate,
            channels
        );

        // 解析用フレーム出力チャンネル
        let (analysis_tx, analysis_rx) = bounded::<AudioFrame>(32);

        let is_playing = self.is_playing.clone();
        let position_samples = self.position_samples.clone();

        let stream_config = cpal::StreamConfig {
            channels,
            sample_rate: cpal::SampleRate(sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let mut current_frame: Option<AudioFrame> = None;
        let mut frame_position = 0usize;

        let stream = device
            .build_output_stream(
                &stream_config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    if !is_playing.load(Ordering::Relaxed) {
                        // 再生停止中は無音
                        data.fill(0.0);
                        return;
                    }

                    let mut i = 0;
                    while i < data.len() {
                        // 新しいフレームが必要な場合
                        if current_frame.is_none() || frame_position >= current_frame.as_ref().unwrap().len() {
                            match source_rx.try_recv() {
                                Ok(frame) => {
                                    // 解析用にフレームを送信
                                    let _ = analysis_tx.try_send(frame.clone());
                                    current_frame = Some(frame);
                                    frame_position = 0;
                                }
                                Err(_) => {
                                    // バッファアンダーラン
                                    data[i..].fill(0.0);
                                    return;
                                }
                            }
                        }

                        if let Some(ref frame) = current_frame {
                            let samples_to_copy = (frame.len() - frame_position).min((data.len() - i) / channels as usize);

                            for j in 0..samples_to_copy {
                                let idx = frame_position + j;
                                let out_idx = i + j * channels as usize;

                                data[out_idx] = frame.left[idx];
                                if channels >= 2 && out_idx + 1 < data.len() {
                                    data[out_idx + 1] = frame.right[idx];
                                }
                            }

                            i += samples_to_copy * channels as usize;
                            frame_position += samples_to_copy;
                            position_samples.fetch_add(samples_to_copy as u64, Ordering::Relaxed);
                        }
                    }
                },
                |err| {
                    tracing::error!("Audio stream error: {}", err);
                },
                None,
            )
            .map_err(|e| WaveError::Audio(format!("Failed to build stream: {}", e)))?;

        self.stream = Some(stream);
        self.analysis_receiver = Some(analysis_rx.clone());

        Ok(analysis_rx)
    }

    /// フレーム送信用のSenderを取得
    pub fn frame_sender(&self) -> Option<Sender<AudioFrame>> {
        self.frame_sender.clone()
    }

    /// 再生開始
    pub fn play(&mut self) -> WaveResult<()> {
        if let Some(ref stream) = self.stream {
            stream
                .play()
                .map_err(|e| WaveError::Audio(format!("Failed to play: {}", e)))?;
            self.is_playing.store(true, Ordering::Relaxed);
            tracing::info!("Audio playback started");
        }
        Ok(())
    }

    /// 再生停止
    pub fn pause(&mut self) -> WaveResult<()> {
        if let Some(ref stream) = self.stream {
            stream
                .pause()
                .map_err(|e| WaveError::Audio(format!("Failed to pause: {}", e)))?;
            self.is_playing.store(false, Ordering::Relaxed);
            tracing::info!("Audio playback paused");
        }
        Ok(())
    }

    /// 再生中かどうか
    pub fn is_playing(&self) -> bool {
        self.is_playing.load(Ordering::Relaxed)
    }

    /// 現在の再生位置（秒）
    pub fn position(&self) -> f64 {
        let samples = self.position_samples.load(Ordering::Relaxed);
        samples as f64 / self.config.sample_rate as f64
    }

    /// 設定を取得
    pub fn config(&self) -> &AudioConfig {
        &self.config
    }
}

impl Drop for AudioPlayer {
    fn drop(&mut self) {
        self.is_playing.store(false, Ordering::Relaxed);
    }
}
