//! オーディオデコーダー
//!
//! symphoniaを使用してオーディオファイルをデコードします。
//! REQ-AUDIO-001: オーディオファイルデコード

use std::fs::File;
use std::path::Path;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use cortex_types::{AudioFrame, WaveError, WaveResult};

/// オーディオデコーダー
pub struct AudioDecoder {
    format: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u16,
    current_time: f64,
}

impl AudioDecoder {
    /// ファイルからデコーダーを作成
    pub fn from_file<P: AsRef<Path>>(path: P) -> WaveResult<Self> {
        let file = File::open(path.as_ref())
            .map_err(|e| WaveError::Decode(format!("Failed to open file: {}", e)))?;

        let mss = MediaSourceStream::new(Box::new(file), Default::default());

        let mut hint = Hint::new();
        if let Some(ext) = path.as_ref().extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }

        let format_opts = FormatOptions::default();
        let metadata_opts = MetadataOptions::default();
        let decoder_opts = DecoderOptions::default();

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &format_opts, &metadata_opts)
            .map_err(|e| WaveError::Decode(format!("Unsupported format: {}", e)))?;

        let format = probed.format;

        let track = format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
            .ok_or_else(|| WaveError::Decode("No audio track found".into()))?;

        let track_id = track.id;
        let codec_params = &track.codec_params;

        let sample_rate = codec_params
            .sample_rate
            .ok_or_else(|| WaveError::Decode("Unknown sample rate".into()))?;

        let channels = codec_params
            .channels
            .map(|c| c.count() as u16)
            .unwrap_or(2);

        let decoder = symphonia::default::get_codecs()
            .make(codec_params, &decoder_opts)
            .map_err(|e| WaveError::Decode(format!("Failed to create decoder: {}", e)))?;

        Ok(Self {
            format,
            decoder,
            track_id,
            sample_rate,
            channels,
            current_time: 0.0,
        })
    }

    /// サンプルレートを取得
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// チャンネル数を取得
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// 次のフレームをデコード
    pub fn decode_frame(&mut self) -> WaveResult<Option<AudioFrame>> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(packet) => packet,
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(None);
                }
                Err(e) => return Err(WaveError::Decode(format!("Failed to read packet: {}", e))),
            };

            if packet.track_id() != self.track_id {
                continue;
            }

            let decoded = match self.decoder.decode(&packet) {
                Ok(decoded) => decoded,
                Err(symphonia::core::errors::Error::DecodeError(e)) => {
                    tracing::warn!("Decode error: {}", e);
                    continue;
                }
                Err(e) => return Err(WaveError::Decode(format!("Failed to decode: {}", e))),
            };

            let spec = *decoded.spec();
            let duration = decoded.capacity();

            let mut sample_buf = SampleBuffer::<f32>::new(duration as u64, spec);
            sample_buf.copy_interleaved_ref(decoded);

            let samples = sample_buf.samples();
            let channels = spec.channels.count();

            let (left, right) = if channels >= 2 {
                let left: Vec<f32> = samples.iter().step_by(channels).copied().collect();
                let right: Vec<f32> = samples.iter().skip(1).step_by(channels).copied().collect();
                (left, right)
            } else {
                let mono: Vec<f32> = samples.to_vec();
                (mono.clone(), mono)
            };

            let frame_duration = left.len() as f64 / self.sample_rate as f64;
            let timestamp = self.current_time;
            self.current_time += frame_duration;

            return Ok(Some(AudioFrame::new(
                left,
                right,
                self.sample_rate,
                timestamp,
            )));
        }
    }

    /// 全フレームをデコードしてVecに格納
    pub fn decode_all(&mut self) -> WaveResult<Vec<AudioFrame>> {
        let mut frames = Vec::new();
        while let Some(frame) = self.decode_frame()? {
            frames.push(frame);
        }
        Ok(frames)
    }
}
