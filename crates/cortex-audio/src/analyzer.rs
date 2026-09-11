//! オーディオ解析
//!
//! FFTとビート検出を行います。
//! REQ-AUDIO-003: オーディオ解析

use rustfft::{num_complex::Complex, FftPlanner};
use std::collections::VecDeque;

use cortex_types::{AnalysisData, AudioFrame, FrequencyBand};

/// オーディオアナライザー
pub struct AudioAnalyzer {
    fft_size: usize,
    sample_rate: u32,
    fft_planner: FftPlanner<f32>,
    window: Vec<f32>,
    spectrum_buffer: Vec<Complex<f32>>,
    // ビート検出用
    energy_history: VecDeque<f32>,
    beat_threshold: f32,
    last_beat_time: f64,
    min_beat_interval: f64,
}

impl AudioAnalyzer {
    /// 新しいアナライザーを作成
    pub fn new(fft_size: usize, sample_rate: u32) -> Self {
        let window = Self::hann_window(fft_size);

        Self {
            fft_size,
            sample_rate,
            fft_planner: FftPlanner::new(),
            window,
            spectrum_buffer: vec![Complex::new(0.0, 0.0); fft_size],
            energy_history: VecDeque::with_capacity(64),
            beat_threshold: 1.5,
            last_beat_time: 0.0,
            min_beat_interval: 0.1, // 100ms (600 BPM max)
        }
    }

    /// Hann窓関数を生成
    fn hann_window(size: usize) -> Vec<f32> {
        (0..size)
            .map(|i| {
                0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / (size - 1) as f32).cos())
            })
            .collect()
    }

    /// フレームを解析
    pub fn analyze(&mut self, frame: &AudioFrame) -> AnalysisData {
        let mono = frame.mono();

        // RMSとピーク計算
        let rms = Self::calculate_rms(&mono);
        let peak = Self::calculate_peak(&mono);

        // FFT
        let spectrum = self.compute_fft(&mono);

        // 周波数帯域エネルギー
        let bass = self.band_energy(&spectrum, FrequencyBand::BASS);
        let mid = self.band_energy(&spectrum, FrequencyBand::MID);
        let high = self.band_energy(&spectrum, FrequencyBand::HIGH);

        // ビート検出
        let (beat_detected, beat_intensity) = self.detect_beat(bass, frame.timestamp);

        AnalysisData {
            rms,
            peak,
            bass,
            mid,
            high,
            beat_detected,
            beat_intensity,
            spectrum: self.normalize_spectrum(&spectrum),
            timestamp: frame.timestamp,
        }
    }

    /// RMS計算
    fn calculate_rms(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum: f32 = samples.iter().map(|s| s * s).sum();
        (sum / samples.len() as f32).sqrt()
    }

    /// ピーク計算
    fn calculate_peak(samples: &[f32]) -> f32 {
        samples.iter().map(|s| s.abs()).fold(0.0f32, f32::max)
    }

    /// FFT計算
    fn compute_fft(&mut self, samples: &[f32]) -> Vec<f32> {
        // サンプルをFFTサイズに調整
        let len = samples.len().min(self.fft_size);
        self.spectrum_buffer.fill(Complex::new(0.0, 0.0));

        for (i, sample) in samples.iter().take(len).enumerate() {
            self.spectrum_buffer[i] = Complex::new(sample * self.window[i], 0.0);
        }

        let fft = self.fft_planner.plan_fft_forward(self.fft_size);
        fft.process(&mut self.spectrum_buffer);

        // マグニチュードを計算（ナイキスト周波数まで）
        self.spectrum_buffer[..self.fft_size / 2]
            .iter()
            .map(|c| c.norm() / self.fft_size as f32)
            .collect()
    }

    /// 周波数帯域のエネルギーを計算
    fn band_energy(&self, spectrum: &[f32], band: FrequencyBand) -> f32 {
        let bin_width = self.sample_rate as f32 / self.fft_size as f32;
        let start_bin = (band.low / bin_width).floor() as usize;
        let end_bin = (band.high / bin_width).ceil() as usize;

        let start = start_bin.clamp(0, spectrum.len() - 1);
        let end = end_bin.clamp(start + 1, spectrum.len());

        if start >= end {
            return 0.0;
        }

        let sum: f32 = spectrum[start..end].iter().map(|&m| m * m).sum();
        (sum / (end - start) as f32).sqrt()
    }

    /// スペクトラムを正規化
    fn normalize_spectrum(&self, spectrum: &[f32]) -> Vec<f32> {
        let max = spectrum.iter().fold(0.0f32, |a, &b| a.max(b));
        if max > 0.0 {
            spectrum.iter().map(|&s| s / max).collect()
        } else {
            vec![0.0; spectrum.len()]
        }
    }

    /// ビート検出
    fn detect_beat(&mut self, bass_energy: f32, timestamp: f64) -> (bool, f32) {
        // エネルギー履歴を更新
        self.energy_history.push_back(bass_energy);
        if self.energy_history.len() > 64 {
            self.energy_history.pop_front();
        }

        if self.energy_history.len() < 8 {
            return (false, 0.0);
        }

        // 平均エネルギーを計算
        let avg_energy: f32 = self.energy_history.iter().sum::<f32>() / self.energy_history.len() as f32;

        // ビート検出
        let beat_detected = bass_energy > avg_energy * self.beat_threshold
            && (timestamp - self.last_beat_time) > self.min_beat_interval;

        let beat_intensity = if avg_energy > 0.0 {
            (bass_energy / avg_energy - 1.0).max(0.0).min(1.0)
        } else {
            0.0
        };

        if beat_detected {
            self.last_beat_time = timestamp;
        }

        (beat_detected, beat_intensity)
    }

    /// ビート検出の閾値を設定
    pub fn set_beat_threshold(&mut self, threshold: f32) {
        self.beat_threshold = threshold.max(1.0);
    }

    /// FFTサイズを取得
    pub fn fft_size(&self) -> usize {
        self.fft_size
    }
}
