//! wave-encoder - 動画エンコード
//!
//! video-rsを使用したH.264/MP4エンコード機能。
//! リアルタイム録画とオフラインレンダリングに対応。
//!
//! ## Features
//!
//! - `ffmpeg`: FFmpegを使用した実際のエンコード機能を有効化
//!   （FFmpegがシステムにインストールされている必要があります）
//!
//! REQ-ENCODER-001: 動画エンコード

use std::path::Path;

use crate::shader_types::EncoderConfig;
#[allow(unused_imports)]
use cortex_types::{WaveError, WaveResult};

// FFmpeg feature有効時の実装
#[cfg(feature = "ffmpeg")]
mod ffmpeg_impl {
    use std::path::Path;
    use std::sync::Once;

    use ndarray::Array3;
    use video_rs::encode::{Encoder, Settings};
    use video_rs::time::Time;

    use crate::shader_types::{EncoderConfig, EncoderPreset, VideoCodec};
    use cortex_types::{WaveError, WaveResult};

    static INIT: Once = Once::new();

    fn init_video_rs() {
        INIT.call_once(|| {
            video_rs::init().expect("Failed to initialize video-rs");
            tracing::info!("video-rs initialized");
        });
    }

    pub struct VideoEncoderInner {
        pub config: EncoderConfig,
        encoder: Option<Encoder>,
        pub frame_count: u64,
        pub is_recording: bool,
        frame_duration: Time,
        current_position: Time,
    }

    impl VideoEncoderInner {
        pub fn new(config: EncoderConfig) -> Self {
            init_video_rs();
            let frame_duration = Time::from_nth_of_a_second(config.fps as usize);

            Self {
                config,
                encoder: None,
                frame_count: 0,
                is_recording: false,
                frame_duration,
                current_position: Time::zero(),
            }
        }

        fn create_settings(&self) -> Settings {
            let settings = match self.config.codec {
                VideoCodec::H264 => {
                    Settings::preset_h264_yuv420p(self.config.width as usize, self.config.height as usize, false)
                }
                VideoCodec::H265 | VideoCodec::VP9 => {
                    tracing::warn!("Codec not directly supported, using H.264");
                    Settings::preset_h264_yuv420p(self.config.width as usize, self.config.height as usize, false)
                }
            };

            match self.config.preset {
                EncoderPreset::Ultrafast => {
                    tracing::debug!("Using ultrafast preset");
                }
                EncoderPreset::Medium => {
                    tracing::debug!("Using medium preset");
                }
                EncoderPreset::Slow => {
                    tracing::debug!("Using slow preset");
                }
            }

            settings
        }

        pub fn start_recording<P: AsRef<Path>>(&mut self, output_path: P) -> WaveResult<()> {
            if self.is_recording {
                return Err(WaveError::Encode("Already recording".into()));
            }

            let settings = self.create_settings();
            let path = output_path.as_ref();

            tracing::info!(
                "Starting recording: {:?} ({}x{} @ {}fps)",
                path,
                self.config.width,
                self.config.height,
                self.config.fps
            );

            let encoder = Encoder::new(path, settings)
                .map_err(|e| WaveError::Encode(format!("Failed to create encoder: {}", e)))?;

            self.encoder = Some(encoder);
            self.frame_count = 0;
            self.current_position = Time::zero();
            self.is_recording = true;

            Ok(())
        }

        pub fn encode_frame(&mut self, rgba_buffer: &[u8]) -> WaveResult<()> {
            if !self.is_recording {
                return Err(WaveError::Encode("Encoder not started".into()));
            }

            let width = self.config.width as usize;
            let height = self.config.height as usize;

            let rgb_frame = self.rgba_to_rgb_array(rgba_buffer, width, height)?;

            let encoder = self
                .encoder
                .as_mut()
                .ok_or_else(|| WaveError::Encode("Encoder not initialized".into()))?;

            encoder
                .encode(&rgb_frame, self.current_position)
                .map_err(|e| WaveError::Encode(format!("Failed to encode frame: {}", e)))?;

            self.current_position = self.current_position.aligned_with(self.frame_duration).add();
            self.frame_count += 1;

            if self.frame_count % 300 == 0 {
                let elapsed = self.frame_count as f64 / self.config.fps as f64;
                tracing::info!("Encoded frame {}, elapsed: {:.1}s", self.frame_count, elapsed);
            }

            Ok(())
        }

        fn rgba_to_rgb_array(
            &self,
            rgba_buffer: &[u8],
            width: usize,
            height: usize,
        ) -> WaveResult<Array3<u8>> {
            let expected_size = width * height * 4;
            if rgba_buffer.len() != expected_size {
                return Err(WaveError::Encode(format!(
                    "Invalid RGBA buffer size: expected {}, got {}",
                    expected_size,
                    rgba_buffer.len()
                )));
            }

            let rgb_frame = Array3::from_shape_fn((height, width, 3), |(y, x, c)| {
                rgba_buffer[(y * width + x) * 4 + c]
            });

            Ok(rgb_frame)
        }

        pub fn stop_recording(&mut self) -> WaveResult<()> {
            if !self.is_recording {
                return Ok(());
            }

            if let Some(mut encoder) = self.encoder.take() {
                encoder
                    .finish()
                    .map_err(|e| WaveError::Encode(format!("Failed to finish encoder: {}", e)))?;

                let duration = self.frame_count as f64 / self.config.fps as f64;
                tracing::info!(
                    "Recording stopped: {} frames, {:.1}s duration",
                    self.frame_count,
                    duration
                );
            }

            self.is_recording = false;
            Ok(())
        }
    }
}

// スタブ実装（FFmpeg未インストール時）
#[cfg(not(feature = "ffmpeg"))]
mod stub_impl {
    use std::path::Path;

    use crate::shader_types::EncoderConfig;
    use cortex_types::{WaveError, WaveResult};

    pub struct VideoEncoderInner {
        pub config: EncoderConfig,
        pub frame_count: u64,
        pub is_recording: bool,
    }

    impl VideoEncoderInner {
        pub fn new(config: EncoderConfig) -> Self {
            Self {
                config,
                frame_count: 0,
                is_recording: false,
            }
        }

        pub fn start_recording<P: AsRef<Path>>(&mut self, output_path: P) -> WaveResult<()> {
            tracing::warn!(
                "Video encoding is not available (compile with 'ffmpeg' feature). \
                 Output path: {:?}",
                output_path.as_ref()
            );

            self.frame_count = 0;
            self.is_recording = true;

            Ok(())
        }

        pub fn encode_frame(&mut self, _rgba_buffer: &[u8]) -> WaveResult<()> {
            if !self.is_recording {
                return Err(WaveError::Encode("Encoder not started".into()));
            }

            self.frame_count += 1;

            if self.frame_count % 300 == 0 {
                tracing::debug!(
                    "Frame {} (stub encoder, elapsed: {:.1}s)",
                    self.frame_count,
                    self.frame_count as f64 / self.config.fps as f64
                );
            }

            Ok(())
        }

        pub fn stop_recording(&mut self) -> WaveResult<()> {
            if self.is_recording {
                let duration = self.frame_count as f64 / self.config.fps as f64;
                tracing::info!(
                    "Stub recording stopped: {} frames, {:.1}s duration",
                    self.frame_count,
                    duration
                );
            }

            self.is_recording = false;
            Ok(())
        }
    }
}

// 共通インターフェース
#[cfg(feature = "ffmpeg")]
use ffmpeg_impl::VideoEncoderInner;
#[cfg(not(feature = "ffmpeg"))]
use stub_impl::VideoEncoderInner;

/// 動画エンコーダー
///
/// video-rsを使用してRGBフレームをH.264/MP4にエンコードします。
/// FFmpegがインストールされていない環境ではスタブ実装が使用されます。
pub struct VideoEncoder {
    inner: VideoEncoderInner,
}

impl VideoEncoder {
    /// 新しいエンコーダーを作成
    pub fn new(config: EncoderConfig) -> Self {
        Self {
            inner: VideoEncoderInner::new(config),
        }
    }

    /// デフォルト設定でエンコーダーを作成
    pub fn with_defaults() -> Self {
        Self::new(EncoderConfig::default())
    }

    /// 録画を開始
    pub fn start_recording<P: AsRef<Path>>(&mut self, output_path: P) -> WaveResult<()> {
        self.inner.start_recording(output_path)
    }

    /// RGBAバッファからフレームをエンコード
    ///
    /// `rgba_buffer`は(width * height * 4)バイトのRGBAデータ。
    pub fn encode_frame(&mut self, rgba_buffer: &[u8]) -> WaveResult<()> {
        self.inner.encode_frame(rgba_buffer)
    }

    /// 録画を停止
    pub fn stop_recording(&mut self) -> WaveResult<()> {
        self.inner.stop_recording()
    }

    /// 録画中かどうか
    pub fn is_recording(&self) -> bool {
        self.inner.is_recording
    }

    /// エンコード済みフレーム数
    pub fn frame_count(&self) -> u64 {
        self.inner.frame_count
    }

    /// 設定を取得
    pub fn config(&self) -> &EncoderConfig {
        &self.inner.config
    }

    /// 現在の録画時間（秒）
    pub fn elapsed_seconds(&self) -> f64 {
        self.inner.frame_count as f64 / self.inner.config.fps as f64
    }

    /// FFmpegサポートが有効かどうか
    pub fn is_ffmpeg_enabled() -> bool {
        cfg!(feature = "ffmpeg")
    }
}

impl Drop for VideoEncoder {
    fn drop(&mut self) {
        if self.is_recording() {
            if let Err(e) = self.stop_recording() {
                tracing::error!("Failed to stop recording on drop: {}", e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encoder_creation() {
        let encoder = VideoEncoder::with_defaults();
        assert!(!encoder.is_recording());
        assert_eq!(encoder.frame_count(), 0);
    }

    #[test]
    fn test_config() {
        let config = EncoderConfig {
            width: 1280,
            height: 720,
            fps: 30,
            ..Default::default()
        };
        let encoder = VideoEncoder::new(config);
        assert_eq!(encoder.config().width, 1280);
        assert_eq!(encoder.config().height, 720);
        assert_eq!(encoder.config().fps, 30);
    }

    #[test]
    fn test_ffmpeg_enabled() {
        // This will be true if compiled with --features ffmpeg
        let enabled = VideoEncoder::is_ffmpeg_enabled();
        println!("FFmpeg support: {}", enabled);
    }

    #[cfg(feature = "ffmpeg")]
    #[test]
    fn records_rgba_frames_to_decodable_mp4() {
        let path = std::env::temp_dir().join(format!("cortex-encoder-{}.mp4", std::process::id()));
        let mut encoder = VideoEncoder::new(EncoderConfig {
            width: 16,
            height: 16,
            fps: 30,
            ..Default::default()
        });
        assert!(encoder.encode_frame(&[]).is_err());
        encoder.start_recording(&path).unwrap();
        assert!(encoder.encode_frame(&[0; 4]).is_err());
        assert_eq!(encoder.frame_count(), 0);
        let rgba = [255, 0, 0, 255].repeat(16 * 16);
        for _ in 0..3 {
            encoder.encode_frame(&rgba).unwrap();
        }
        encoder.stop_recording().unwrap();
        assert!(!encoder.is_recording());
        assert_eq!(encoder.frame_count(), 3);
        assert!((encoder.elapsed_seconds() - 0.1).abs() < f64::EPSILON);

        // ⚠️ 既知（上流 video-rs 0.12.0 + FFmpeg 9、2026-10-17 実測）: 読み戻せるのは
        // **書いた数 - 1**。video-rs は最後のパケットに長さを付けないので、MP4 の最後の
        // サンプルが長さ 0 になり捨てられる（ffprobe でも nb_frames=3 / 読めるのは 2）。
        // B フレームを切っても `use_editlist=0` でも変わらなかった。上流で直ったら
        // この数が 3 に戻ってテストが落ちる — そのとき 3 に直す
        let mut decoder = video_rs::decode::Decoder::new(path.as_path()).unwrap();
        assert_eq!(decoder.size(), (16, 16));
        for _ in 0..2 {
            let (_, frame) = decoder.decode().unwrap();
            assert_eq!(frame.shape(), &[16, 16, 3]);
            assert!(frame[[0, 0, 0]] > 200);
            assert!(frame[[0, 0, 1]] < 30);
        }
        assert!(decoder.decode().is_err());
        drop(decoder);
        std::fs::remove_file(path).unwrap();
    }
}
