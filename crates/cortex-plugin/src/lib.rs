//! wave-plugin: VST3/AudioUnit プラグインホスティング
//!
//! rack crate をバックエンドとして、エフェクトチェーンと
//! インストゥルメント音源の両方に対応したプラグインホスティング機能を提供する。
//!
//! REQ-PLUGIN-001: プラグインホスティング統合

pub mod effect_chain;
pub mod error;
pub mod host;
pub mod instrument;
pub mod instrument_rack;
pub mod midi_convert;
pub mod mixer;
pub mod param_bridge;
pub mod slot;

// Re-exports
pub use effect_chain::EffectChain;
pub use error::{PluginError, PluginResult};
pub use host::{PluginCommand, PluginHost, PluginProcessor, PluginResponse};
pub use instrument::InstrumentSlot;
pub use instrument_rack::{InstrumentRack, NUM_SLOTS};
pub use midi_convert::MidiEvent;
pub use mixer::AudioMixer;
pub use param_bridge::ParamBridge;
pub use slot::PluginSlot;

// rack types re-export
pub use rack::prelude::{PluginInfo, PluginScanner, PluginType, Scanner};

/// システムにインストールされたプラグインをスキャンして一覧表示する
pub fn scan_plugins() -> PluginResult<Vec<PluginInfo>> {
    let scanner = Scanner::new().map_err(|e| PluginError::Scanner(e.to_string()))?;
    let plugins = scanner
        .scan()
        .map_err(|e| PluginError::Scanner(e.to_string()))?;

    for (i, plugin) in plugins.iter().enumerate() {
        tracing::info!(
            "[{}] {} by {} ({:?})",
            i,
            plugin.name,
            plugin.manufacturer,
            plugin.plugin_type,
        );
    }

    Ok(plugins)
}

/// 名前でプラグインを検索する
pub fn find_plugin_by_name(plugins: &[PluginInfo], name: &str) -> Option<usize> {
    plugins.iter().position(|p| p.name.contains(name))
}

/// プラグインタイプでフィルタリングする
pub fn filter_by_type(plugins: &[PluginInfo], plugin_type: PluginType) -> Vec<&PluginInfo> {
    plugins
        .iter()
        .filter(|p| p.plugin_type == plugin_type)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_plugins() {
        let result = scan_plugins();
        match result {
            Ok(plugins) => {
                println!("Found {} plugins:", plugins.len());
                for plugin in &plugins {
                    println!(
                        "  - {} by {} ({:?}) [{}]",
                        plugin.name, plugin.manufacturer, plugin.plugin_type, plugin.unique_id,
                    );
                }
            }
            Err(e) => {
                println!("Scanner error: {}", e);
            }
        }
    }

    /// ライブ経路の回帰テスト: デコーダー実寸（1152サンプル）のフレームが
    /// max_buffer_size（1024）を超えていても、インストゥルメントロード後に
    /// プラグインスレッドが panic せず音声を生成すること。
    ///
    /// 実バグ: scratch バッファ（1024）に 1152 フレームで範囲外アクセスし
    /// プラグインスレッドが死んで全音声が停止していた。
    #[test]
    fn test_processor_live_path_with_oversized_frames() {
        use cortex_types::AudioFrame;
        use std::time::Duration;

        const MAX_BUFFER: usize = 1024;
        const DECODER_FRAME: usize = 1152; // Narrow Down.wav の実測パケットサイズ

        let (host, processor, frame_tx, processed_rx) =
            PluginHost::new(48000.0, MAX_BUFFER).expect("host init failed");

        let serum_idx = host
            .plugins()
            .iter()
            .position(|p| p.name.contains("Serum") && p.plugin_type == PluginType::Instrument);
        let Some(serum_idx) = serum_idx else {
            println!("Serum 2 (Instrument) not found, skipping");
            return;
        };

        let processor_handle = std::thread::spawn(move || processor.run());

        // インストゥルメントロード → 完了待ち
        host.load_instrument(serum_idx).unwrap();
        let mut loaded = false;
        for _ in 0..100 {
            for resp in host.poll_responses() {
                match resp {
                    PluginResponse::InstrumentLoaded { name } => {
                        println!("Loaded: {}", name);
                        loaded = true;
                    }
                    PluginResponse::Error { message } => panic!("Load error: {}", message),
                    _ => {}
                }
            }
            if loaded {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(loaded, "Instrument load timed out");

        // ノートを送って、デコーダー実寸フレームを流す
        host.send_midi(vec![MidiEvent::NoteOn {
            channel: 0,
            note: 48,
            velocity: 100,
        }])
        .unwrap();

        let mut max_rms = 0.0f32;
        let mut received = 0usize;
        for _ in 0..40 {
            let frame = AudioFrame::new(
                vec![0.0; DECODER_FRAME],
                vec![0.0; DECODER_FRAME],
                48000,
                0.0,
            );
            if frame_tx.send(frame).is_err() {
                break; // プロセッサ死亡（panic）でチャンネル切断
            }
            if let Ok(out) = processed_rx.recv_timeout(Duration::from_secs(2)) {
                let n = out.len().max(1);
                let rms: f32 = (out.left.iter().map(|x| x * x).sum::<f32>() / n as f32).sqrt();
                max_rms = max_rms.max(rms);
                received += 1;
            }
        }

        host.shutdown().unwrap();
        processor_handle
            .join()
            .expect("processor thread panicked (scratch buffer overflow?)");

        println!("Received {} frames, max RMS: {:.6}", received, max_rms);
        assert!(received > 0, "No processed frames received");
        assert!(
            max_rms > 0.001,
            "No sound in live path (max RMS = {})",
            max_rms
        );
    }

    #[test]
    fn test_serum2_instrument_midi() {
        let scanner = Scanner::new().unwrap();
        let plugins = scanner.scan().unwrap();

        // Serum 2 の Instrument を探す（"Serum 2 FX" は Effect なのでタイプで絞る）
        let target = plugins
            .iter()
            .enumerate()
            .find(|(_, p)| p.name.contains("Serum") && p.plugin_type == PluginType::Instrument);

        let Some((idx, info)) = target else {
            println!("Serum 2 (Instrument) not found, skipping");
            return;
        };
        println!(">>> Loading: {} ({}) <<<", info.name, info.unique_id);

        let mut slot =
            PluginSlot::load(&scanner, &plugins[idx], 48000.0, 512).expect("Failed to load");
        println!("Serum 2 loaded via PluginSlot");

        let num_frames = 512;
        let mut left_out = vec![0.0f32; num_frames];
        let mut right_out = vec![0.0f32; num_frames];

        // 無音ベースライン
        slot.process_instrument(&mut left_out, &mut right_out, num_frames);
        let silent_rms: f32 =
            (left_out.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();
        println!("Silent RMS (no note): {:.6}", silent_rms);

        // MIDI Note On (C3 = 48)
        slot.send_midi(&[MidiEvent::NoteOn {
            channel: 0,
            note: 48,
            velocity: 100,
        }])
        .expect("Failed to send MIDI");

        // Serum は初期化に時間がかかる場合があるため多めのブロックを処理
        let mut max_rms = 0.0f32;
        for block in 0..32 {
            left_out.fill(0.0);
            right_out.fill(0.0);
            slot.process_instrument(&mut left_out, &mut right_out, num_frames);

            let rms: f32 = (left_out.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();
            if block % 4 == 0 {
                println!("  Block {}: RMS={:.6}", block, rms);
            }
            max_rms = max_rms.max(rms);
        }

        slot.send_midi(&[MidiEvent::NoteOff {
            channel: 0,
            note: 48,
            velocity: 64,
        }])
        .unwrap();

        println!("\nMax RMS during note: {:.6}", max_rms);
        assert!(
            max_rms > 0.001,
            "Serum 2 produced no sound (max RMS = {})",
            max_rms
        );
        println!("Serum 2 sound generation: OK");
    }

    #[test]
    fn test_list_effects() {
        let scanner = Scanner::new().unwrap();
        let plugins = scanner.scan().unwrap();

        let effects = filter_by_type(&plugins, PluginType::Effect);
        println!("\n=== Effect Plugins ({}) ===", effects.len());
        for fx in &effects {
            println!("  - {} by {}", fx.name, fx.manufacturer);
        }
    }

    #[test]
    fn test_list_instruments() {
        let scanner = Scanner::new().unwrap();
        let plugins = scanner.scan().unwrap();

        let instruments = filter_by_type(&plugins, PluginType::Instrument);
        println!("\n=== Instrument Plugins ({}) ===", instruments.len());
        for inst in &instruments {
            println!("  - {} by {}", inst.name, inst.manufacturer);
        }
    }

    #[test]
    fn test_load_reverb_effect() {
        let scanner = Scanner::new().unwrap();
        let plugins = scanner.scan().unwrap();

        // Apple AUReverb2 を探す
        let idx = find_plugin_by_name(&plugins, "AUReverb2");
        if idx.is_none() {
            println!("AUReverb2 not found, skipping test");
            return;
        }
        let idx = idx.unwrap();
        println!("Found: {} ({})", plugins[idx].name, plugins[idx].unique_id);

        // PluginSlot 経由でロード
        let mut slot =
            PluginSlot::load(&scanner, &plugins[idx], 48000.0, 512).expect("Failed to load plugin");
        println!("Plugin loaded via PluginSlot");

        // パラメータ一覧
        let param_count = slot.parameter_count();
        println!("\nParameters ({}):", param_count);
        for i in 0..param_count {
            if let Ok(info) = slot.parameter_info(i) {
                let value = slot.get_parameter(i).unwrap_or(-1.0);
                println!(
                    "  [{}] {} = {:.3} (range: {:.1} - {:.1})",
                    i, info.name, value, info.min, info.max,
                );
            }
        }

        // パラメータ設定
        slot.set_parameter(0, 1.0).unwrap();
        slot.set_parameter(4, 0.5).unwrap();
        slot.set_parameter(5, 0.25).unwrap();

        // テスト音声: 440Hz サイン波
        let num_frames = 512;
        let mut left: Vec<f32> = (0..num_frames)
            .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 48000.0).sin() * 0.5)
            .collect();
        let mut right = left.clone();

        let input_rms: f32 = (left.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();

        // エフェクト処理
        slot.process_effect(&mut left, &mut right, num_frames);

        let output_rms: f32 = (left.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();

        println!("\n=== Audio Processing Results ===");
        println!("Input  RMS: {:.6}", input_rms);
        println!("Output RMS: {:.6}", output_rms);

        let has_output = left.iter().any(|x| x.abs() > 0.0001);
        println!("Has non-zero output: {}", has_output);
    }

    #[test]
    fn test_korg_synth_midi() {
        let scanner = Scanner::new().unwrap();
        let plugins = scanner.scan().unwrap();

        // KORGインストゥルメントを一覧表示
        let korg_instruments: Vec<_> = plugins
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                p.manufacturer.contains("KORG") && p.plugin_type == PluginType::Instrument
            })
            .collect();

        println!("=== KORG Instruments ({}) ===", korg_instruments.len());
        for (idx, inst) in &korg_instruments {
            println!("  [{}] {} ({})", idx, inst.name, inst.unique_id);
        }

        if korg_instruments.is_empty() {
            println!("No KORG instruments found, skipping");
            return;
        }

        // Memphis (MS-20) を優先、なければ最初のKORGシンセ
        let target = korg_instruments
            .iter()
            .find(|(_, p)| p.name.contains("Memphis"))
            .or_else(|| korg_instruments.first());

        let (idx, info) = target.unwrap();
        println!("\n>>> Loading: {} <<<", info.name);

        // PluginSlot 経由でロード
        let mut slot =
            PluginSlot::load(&scanner, &plugins[*idx], 48000.0, 512).expect("Failed to load");
        println!("Loaded via PluginSlot");

        // MIDI ノートテスト
        println!("\n=== MIDI Note Test ===");

        let num_frames = 512;
        let mut left_out = vec![0.0f32; num_frames];
        let mut right_out = vec![0.0f32; num_frames];

        // 無音ベースライン
        slot.process_instrument(&mut left_out, &mut right_out, num_frames);
        let silent_rms: f32 =
            (left_out.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();
        println!("Silent RMS (no note): {:.6}", silent_rms);

        // MIDI Note On (C4)
        let note_on = vec![MidiEvent::NoteOn {
            channel: 0,
            note: 60,
            velocity: 100,
        }];
        slot.send_midi(&note_on).expect("Failed to send MIDI");
        println!("MIDI Note On sent: C4 (60), velocity 100");

        // ノートOn後にオーディオ処理
        let mut max_rms = 0.0f32;
        for block in 0..8 {
            left_out.fill(0.0);
            right_out.fill(0.0);
            slot.process_instrument(&mut left_out, &mut right_out, num_frames);

            let rms: f32 = (left_out.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();
            let peak: f32 = left_out.iter().map(|x| x.abs()).fold(0.0f32, f32::max);
            max_rms = max_rms.max(rms);
            println!("  Block {}: RMS={:.6}, Peak={:.6}", block, rms, peak);
        }

        // Note Off
        let note_off = vec![MidiEvent::NoteOff {
            channel: 0,
            note: 60,
            velocity: 64,
        }];
        slot.send_midi(&note_off).unwrap();
        println!("\nMIDI Note Off sent");

        // リリース処理
        for block in 0..4 {
            left_out.fill(0.0);
            right_out.fill(0.0);
            slot.process_instrument(&mut left_out, &mut right_out, num_frames);

            let rms: f32 = (left_out.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();
            println!("  Release {}: RMS={:.6}", block, rms);
        }

        println!("\n=== Results ===");
        println!("Max RMS during note: {:.6}", max_rms);
        println!("Sound was generated: {}", max_rms > 0.001);

        // 和音テスト
        println!("\n=== Chord Test (C Major: C4-E4-G4) ===");
        let chord = vec![
            MidiEvent::NoteOn {
                channel: 0,
                note: 60,
                velocity: 100,
            },
            MidiEvent::NoteOn {
                channel: 0,
                note: 64,
                velocity: 100,
            },
            MidiEvent::NoteOn {
                channel: 0,
                note: 67,
                velocity: 100,
            },
        ];
        slot.send_midi(&chord).unwrap();
        println!("Chord sent: C4 + E4 + G4");

        for block in 0..4 {
            left_out.fill(0.0);
            right_out.fill(0.0);
            slot.process_instrument(&mut left_out, &mut right_out, num_frames);

            let rms: f32 = (left_out.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();
            let peak: f32 = left_out.iter().map(|x| x.abs()).fold(0.0f32, f32::max);
            println!("  Block {}: RMS={:.6}, Peak={:.6}", block, rms, peak);
        }

        // 全ノートオフ
        let chord_off = vec![
            MidiEvent::NoteOff {
                channel: 0,
                note: 60,
                velocity: 64,
            },
            MidiEvent::NoteOff {
                channel: 0,
                note: 64,
                velocity: 64,
            },
            MidiEvent::NoteOff {
                channel: 0,
                note: 67,
                velocity: 64,
            },
        ];
        slot.send_midi(&chord_off).unwrap();
        println!("All notes off");
    }

    #[test]
    fn test_effect_chain() {
        let scanner = Scanner::new().unwrap();
        let plugins = scanner.scan().unwrap();

        // AUReverb2 でエフェクトチェーンテスト
        let reverb_idx = find_plugin_by_name(&plugins, "AUReverb2");
        if reverb_idx.is_none() {
            println!("AUReverb2 not found, skipping effect chain test");
            return;
        }
        let reverb_idx = reverb_idx.unwrap();

        let mut chain = EffectChain::new();
        chain
            .push(&scanner, &plugins[reverb_idx], 48000.0, 512)
            .expect("Failed to add effect");

        assert_eq!(chain.len(), 1);
        println!("Effect chain has {} effect(s)", chain.len());

        // テスト音声
        let num_frames = 512;
        let mut left: Vec<f32> = (0..num_frames)
            .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 48000.0).sin() * 0.5)
            .collect();
        let mut right = left.clone();

        let input_rms: f32 = (left.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();

        chain.process(&mut left, &mut right, num_frames);

        let output_rms: f32 = (left.iter().map(|x| x * x).sum::<f32>() / num_frames as f32).sqrt();

        println!("Input  RMS: {:.6}", input_rms);
        println!("Output RMS: {:.6}", output_rms);
        println!("Chain processed successfully");
    }
}
