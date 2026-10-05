//! オーディオデコーダー
//!
//! symphoniaを使用してオーディオファイルをデコードします。
//! REQ-AUDIO-001: オーディオファイルデコード

use std::fs::File;
use std::path::Path;

use symphonia::core::codecs::audio::{AudioDecoderOptions, CODEC_ID_NULL_AUDIO};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::formats::probe::Hint;

use cortex_types::{AudioFrame, WaveError, WaveResult};

/// オーディオデコーダー
pub struct AudioDecoder {
    format: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::audio::AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u16,
    current_time: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode_pcm_wav(channels: u16) {
        let frames = 5000usize;
        let rate = 48000u32;
        let data_len = (frames * channels as usize * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&channels.to_le_bytes());
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * channels as u32 * 2).to_le_bytes());
        wav.extend_from_slice(&(channels * 2).to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        for index in 0..frames {
            let sample = [-16384i16, 0, 16384][index % 3];
            wav.extend_from_slice(&sample.to_le_bytes());
            if channels == 2 {
                wav.extend_from_slice(&(-sample).to_le_bytes());
            }
        }
        let path = std::env::temp_dir().join(format!(
            "cortex-decoder-{}-{channels}.wav", std::process::id()
        ));
        std::fs::write(&path, wav).unwrap();
        let mut decoder = AudioDecoder::from_file(&path).unwrap();
        assert_eq!(decoder.sample_rate(), rate);
        assert_eq!(decoder.channels(), channels);
        let mut decoded_frames = 0;
        while let Some(frame) = decoder.decode_frame().unwrap() {
            assert!((frame.timestamp - decoded_frames as f64 / rate as f64).abs() < 1e-9);
            assert_eq!(frame.sample_rate, rate);
            assert_eq!(frame.left.len(), frame.right.len());
            for (left, right) in frame.left.iter().zip(&frame.right) {
                let expected = [-0.5f32, 0.0, 0.5][decoded_frames % 3];
                assert_eq!(*left, expected);
                assert_eq!(*right, if channels == 2 { -expected } else { expected });
                decoded_frames += 1;
            }
        }
        assert_eq!(decoded_frames, frames);
        assert!(decoder.decode_frame().unwrap().is_none());
        drop(decoder);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn decodes_stereo_samples_timestamps_and_eof() {
        decode_pcm_wav(2);
    }

    #[test]
    fn duplicates_mono_into_both_output_channels() {
        decode_pcm_wav(1);
    }
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
        let decoder_opts = AudioDecoderOptions::default();

        let format = symphonia::default::get_probe()
            .probe(&hint, mss, format_opts, metadata_opts)
            .map_err(|e| WaveError::Decode(format!("Unsupported format: {}", e)))?;

        let (track_id, codec_params) = format
            .tracks()
            .iter()
            .find_map(|track| {
                let params = track.codec_params.as_ref()?.audio()?;
                (params.codec != CODEC_ID_NULL_AUDIO).then_some((track.id, params))
            })
            .ok_or_else(|| WaveError::Decode("No audio track found".into()))?;

        let sample_rate = codec_params
            .sample_rate
            .ok_or_else(|| WaveError::Decode("Unknown sample rate".into()))?;

        let channels = codec_params
            .channels
            .as_ref()
            .map(|c| c.count() as u16)
            .unwrap_or(2);

        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(codec_params, &decoder_opts)
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
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(None),
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(None);
                }
                Err(e) => return Err(WaveError::Decode(format!("Failed to read packet: {}", e))),
            };

            if packet.track_id != self.track_id {
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

            let channels = decoded.spec().channels().count();
            let mut samples = Vec::<f32>::new();
            decoded.copy_to_vec_interleaved(&mut samples);

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
