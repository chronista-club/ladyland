//! bikeboy-cortex
//!
//! オーディオ・ビジュアル・デバイス統合コントロールシステム
//!
//! サウンドファイルのリアルタイム再生、MIDIコントロールによるビジュアル操作、
//! AudioUnitプラグイン制御、MARUデバイス連携、HD動画録画を統合します。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use anyhow::{Context, Result};
use crossbeam_channel::Sender;
use tracing::{info, warn};
use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{Window, WindowAttributes, WindowId};

use cortex_audio::{AudioAnalyzer, AudioDecoder, AudioPlayer};
use cortex_types::{AnalysisData, AudioFrame};
use cortex_gpu::{EncoderConfig, RenderConfig, ShaderUniforms};
use cortex_gpu::VideoEncoder;
use cortex_midi::{MidiController, MidiHandler};
use cortex_plugin::param_bridge::{ParamBridge, ParamTarget};
use cortex_plugin::{PluginCommand, PluginHost, PluginResponse, PluginType};
use cortex_device::MaruServer;
use cortex_config::PresetManager;
use cortex_gpu::{pipeline::create_uniform_bind_group_layout, shader, Renderer, ShaderPipeline};

/// MIDI CC のルーティング境界
/// CC 0-7 → ビジュアル（MidiController）
/// CC 20+ → プラグインパラメータ（ParamBridge経由）
const VISUAL_CC_MAX: u8 = 7;

/// アプリケーション設定
#[derive(Debug, Clone)]
pub struct AppConfig {
    /// オーディオファイルパス
    pub audio_file: Option<PathBuf>,
    /// 出力動画パス
    pub output_file: Option<PathBuf>,
    /// ウィンドウ幅
    pub width: u32,
    /// ウィンドウ高さ
    pub height: u32,
    /// 録画を有効にするか
    pub record: bool,
    /// VSync
    pub vsync: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            // デフォルトでバンド演奏ファイルを使用
            audio_file: Some(PathBuf::from("./assets/Narrow Down.wav")),
            output_file: None,
            width: 1920,
            height: 1080,
            record: false,
            vsync: true,
        }
    }
}

/// アプリケーション状態
struct App {
    config: AppConfig,
    window: Option<Arc<Window>>,
    renderer: Option<Renderer>,
    uniforms: ShaderUniforms,
    start_time: Instant,
    last_frame_time: Instant,
    // Components
    audio_player: Option<AudioPlayer>,
    audio_analyzer: Option<AudioAnalyzer>,
    midi_handler: Option<MidiHandler>,
    midi_controller: MidiController,
    preset_manager: PresetManager,
    video_encoder: Option<VideoEncoder>,
    // Plugin system
    plugin_host: Option<PluginHost>,
    param_bridge: ParamBridge,
    effect_bypass: bool,
    // MARU device
    maru_handle: Option<cortex_device::server::MaruHandle>,
    // Audio pipeline
    frame_sender: Option<Sender<AudioFrame>>,
    latest_analysis: Arc<Mutex<Option<AnalysisData>>>,
    decoder_running: Arc<AtomicBool>,
    // State
    is_playing: bool,
    is_recording: bool,
    frame_count: u64,
    // Keyboard performance mode（PCキーボード演奏）
    performance_mode: bool,
    /// 演奏モードの基準ノート（Aキーの音。デフォルト C4 = 60）
    keyboard_base_note: u8,
    /// 押下中のキー → 発音したノート番号（オクターブ変更後も正しく消音するため）
    pressed_note_keys: HashMap<KeyCode, u8>,
    /// Iキーによるインストゥルメント循環選択の位置
    instrument_cycle: usize,
    /// MIDI focus（design/03-midi-focus-model.md）
    /// true = ハードウェアMIDIを外部アプリ（VP/Bastet）に譲り、bikeboyは無視する
    midi_focus_external: bool,
    /// X-Touch Main フェーダー連携（接続されていれば Some）
    xtouch: Option<cortex_midi::XTouchMainFader>,
    /// マスターゲインのシャドウ（フェーダー同期・focus復帰時のスナップ用）
    master_gain: f32,
    // Text overlay data
    audio_filename: String,
    audio_timestamp: f64,
}

impl App {
    fn new(config: AppConfig) -> Self {
        Self {
            config,
            window: None,
            renderer: None,
            uniforms: ShaderUniforms::default(),
            start_time: Instant::now(),
            last_frame_time: Instant::now(),
            audio_player: None,
            audio_analyzer: None,
            midi_handler: None,
            midi_controller: MidiController::new(),
            preset_manager: PresetManager::new(),
            video_encoder: None,
            plugin_host: None,
            param_bridge: ParamBridge::new(),
            effect_bypass: false,
            maru_handle: None,
            frame_sender: None,
            latest_analysis: Arc::new(Mutex::new(None)),
            decoder_running: Arc::new(AtomicBool::new(false)),
            is_playing: false,
            is_recording: false,
            frame_count: 0,
            performance_mode: false,
            keyboard_base_note: 60,
            pressed_note_keys: HashMap::new(),
            instrument_cycle: 0,
            midi_focus_external: false,
            xtouch: None,
            master_gain: 1.0,
            audio_filename: String::new(),
            audio_timestamp: 0.0,
        }
    }

    async fn initialize_renderer(&mut self, window: Arc<Window>) -> Result<()> {
        let render_config = RenderConfig {
            width: self.config.width,
            height: self.config.height,
            vsync: self.config.vsync,
            ..Default::default()
        };

        let mut renderer = Renderer::new(window.clone(), render_config)
            .await
            .context("Failed to create renderer")?;

        // シェーダーパイプラインを作成
        let bind_group_layout = create_uniform_bind_group_layout(renderer.device());
        let pipeline = ShaderPipeline::from_wgsl(
            renderer.device(),
            shader::GEOMETRIC_SHADER,
            renderer.surface_format(),
            &bind_group_layout,
        )
        .context("Failed to create shader pipeline")?;

        renderer.set_pipeline(pipeline);
        renderer.initialize_text_overlay();
        self.renderer = Some(renderer);

        info!("Renderer initialized");
        Ok(())
    }

    fn initialize_midi(&mut self) -> Result<()> {
        let mut handler = MidiHandler::new().context("Failed to create MIDI handler")?;

        // 利用可能なMIDIポートを表示
        let ports = MidiHandler::list_ports().unwrap_or_default();
        if ports.is_empty() {
            warn!("No MIDI devices found");
        } else {
            info!("Available MIDI ports:");
            for port in &ports {
                info!("  - {}", port);
            }

            // Keystageに自動接続を試みる
            if let Err(e) = handler.connect_keystage() {
                warn!("Failed to connect to MIDI: {}", e);
            }

            // X-Touch Main フェーダーに接続（任意デバイス。無ければスキップ）
            match cortex_midi::XTouchMainFader::connect() {
                Ok(mut xtouch) => {
                    // モーターフェーダーを現在のマスターゲイン位置へ
                    if let Err(e) = xtouch.project_gain(self.master_gain) {
                        warn!("X-Touch initial fader position failed: {}", e);
                    }
                    info!("X-Touch connected: Main fader ⇄ master gain sync");
                    self.xtouch = Some(xtouch);
                }
                Err(e) => {
                    info!("X-Touch not connected ({})", e);
                }
            }
        }

        self.midi_handler = Some(handler);
        Ok(())
    }

    fn initialize_audio(&mut self) -> Result<()> {
        let mut player =
            AudioPlayer::with_defaults().context("Failed to create audio player")?;

        // プラグインシステムを初期化し、パイプラインに挿入
        let (analysis_rx, plugin_frame_tx) = match self.initialize_plugin_pipeline(&mut player) {
            Ok((analysis_rx, frame_tx)) => (analysis_rx, Some(frame_tx)),
            Err(e) => {
                // プラグインシステム初期化失敗時はフォールバック（直接パイプライン）
                warn!("Plugin system unavailable, using direct pipeline: {}", e);
                let analysis_rx = player.initialize().context("Failed to initialize audio")?;
                let frame_tx = player.frame_sender();
                (analysis_rx, frame_tx)
            }
        };

        // frame_sender を保存（デコーダー→プラグインスレッド or デコーダー→cpal）
        self.frame_sender = plugin_frame_tx;

        // 解析スレッドを開始
        let sample_rate = player.config().sample_rate;
        let mut analyzer = AudioAnalyzer::new(2048, sample_rate);
        let latest_analysis = self.latest_analysis.clone();
        thread::spawn(move || {
            while let Ok(frame) = analysis_rx.recv() {
                let analysis = analyzer.analyze(&frame);
                if let Ok(mut guard) = latest_analysis.lock() {
                    *guard = Some(analysis);
                }
            }
        });

        // ストリームは常時再生してライブ演奏クロックを維持する。
        // ファイル再生の一時停止は PluginProcessor 側の SetFilePlaying で制御する。
        if let Err(e) = player.play() {
            warn!("Failed to start audio stream: {}", e);
        }

        self.audio_player = Some(player);
        self.audio_analyzer = None;

        // 起動時にインストゥルメントを自動ロード（Serum優先）
        // → ウィンドウ操作なしで、起動してすぐMIDIキーボードで演奏できる
        if let Some(ref host) = self.plugin_host {
            let instruments = host.filter_plugins(PluginType::Instrument);
            if let Some(pos) = instruments
                .iter()
                .position(|(_, p)| p.name.contains("Serum"))
            {
                let (plugin_index, info) = instruments[pos];
                info!("Auto-loading instrument: {}", info.name);
                if let Err(e) = host.load_instrument(plugin_index) {
                    warn!("Failed to auto-load instrument: {}", e);
                }
                // Iキーの循環は次の音源から始める
                self.instrument_cycle = pos + 1;
            }
        }

        // MARU サーバーを起動
        let maru_handle = MaruServer::new().start();
        self.maru_handle = Some(maru_handle);

        info!("Audio initialized with analysis thread");
        Ok(())
    }

    /// プラグインパイプラインを初期化
    ///
    /// Decoder → frame_tx → PluginThread → processed_rx → cpal → analysis_rx
    fn initialize_plugin_pipeline(
        &mut self,
        player: &mut AudioPlayer,
    ) -> Result<(
        crossbeam_channel::Receiver<AudioFrame>,
        Sender<AudioFrame>,
    )> {
        // 実デバイスのサンプルレートでプラグインを初期化する
        // （不一致だとインストゥルメントのピッチがずれる）
        let sample_rate = AudioPlayer::default_output_sample_rate().unwrap_or(48000) as f64;
        let max_buffer_size = 1024;
        info!("Plugin sample rate: {} Hz", sample_rate);

        // PluginHost + PluginProcessor ペアを作成
        let (host, processor, frame_tx, processed_rx) =
            PluginHost::new(sample_rate, max_buffer_size)
                .map_err(|e| anyhow::anyhow!("Plugin system init failed: {}", e))?;

        info!(
            "Plugin system initialized: {} plugins available",
            host.plugins().len()
        );

        // cpal を processed_rx（プラグイン処理済み）から受信するように初期化
        let analysis_rx = player
            .initialize_with_source(processed_rx)
            .context("Failed to initialize audio with plugin source")?;

        // プラグインスレッドを起動
        thread::spawn(move || {
            processor.run();
        });

        self.plugin_host = Some(host);

        Ok((analysis_rx, frame_tx))
    }

    /// オーディオファイルをロードして再生を開始
    fn load_audio_file(&mut self, path: &PathBuf) -> Result<()> {
        let decoder_running = self.decoder_running.clone();
        let frame_sender = self
            .frame_sender
            .clone()
            .ok_or_else(|| anyhow::anyhow!("Audio not initialized"))?;

        // ファイル名を保存（テキストオーバーレイ用）
        self.audio_filename = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();

        // 既存のデコーダーを停止
        decoder_running.store(false, Ordering::SeqCst);
        thread::sleep(std::time::Duration::from_millis(100));

        // デコーダースレッドを開始
        let path_for_thread = path.clone();
        let path_for_log = path.clone();
        decoder_running.store(true, Ordering::SeqCst);

        thread::spawn(move || {
            match AudioDecoder::from_file(&path_for_thread) {
                Ok(mut decoder) => {
                    info!(
                        "Loaded audio: {} Hz, {} channels",
                        decoder.sample_rate(),
                        decoder.channels()
                    );

                    while decoder_running.load(Ordering::SeqCst) {
                        match decoder.decode_frame() {
                            Ok(Some(frame)) => {
                                // フレームを送信（プラグインスレッドへ、またはcpalへ直接）
                                if frame_sender.send(frame).is_err() {
                                    break;
                                }
                            }
                            Ok(None) => {
                                info!("Audio file finished");
                                break;
                            }
                            Err(e) => {
                                warn!("Decode error: {}", e);
                                break;
                            }
                        }
                    }
                }
                Err(e) => {
                    warn!("Failed to open audio file: {}", e);
                }
            }
            info!("Decoder thread stopped");
        });

        info!("Started decoding: {:?}", path_for_log);
        Ok(())
    }

    fn update(&mut self) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.start_time).as_secs_f32();
        let delta = now.duration_since(self.last_frame_time).as_secs_f32();
        self.last_frame_time = now;

        // MIDIイベントを処理（ルーティング付き）
        if let Some(ref midi_handler) = self.midi_handler {
            let events = midi_handler.poll_events();
            self.route_midi_events(&events);
        }

        // X-Touch Main フェーダー → マスターゲイン
        // focus=external 中もポーリングは続ける（タッチ状態の追従 + 古いイベントの破棄）が、
        // ゲインへの適用は bikeboy が focus を持つときだけ
        if let Some(ref mut xtouch) = self.xtouch {
            let fader_gain = xtouch.poll_gain();
            if !self.midi_focus_external {
                if let Some(gain) = fader_gain {
                    self.master_gain = gain;
                    if let Some(ref host) = self.plugin_host {
                        let _ = host.send_command(PluginCommand::SetMasterGain { gain });
                    }
                }
            }
        }

        // ParamBridge スムージング tick → 滑らかにパラメータ変更を送信
        {
            let changes = self.param_bridge.tick();
            if let Some(ref host) = self.plugin_host {
                for change in &changes {
                    match &change.target {
                        ParamTarget::Effect { chain_index } => {
                            let _ = host.send_command(PluginCommand::SetEffectParam {
                                chain_index: *chain_index,
                                param_index: change.param_index,
                                value: change.value,
                            });
                        }
                        ParamTarget::Instrument => {
                            let _ = host.send_command(PluginCommand::SetInstrumentParam {
                                param_index: change.param_index,
                                value: change.value,
                            });
                        }
                    }
                }
            }
        }

        // プラグインレスポンスを処理
        if let Some(ref host) = self.plugin_host {
            for response in host.poll_responses() {
                match response {
                    PluginResponse::EffectLoaded {
                        chain_index,
                        name,
                        param_count,
                        ref params,
                    } => {
                        info!(
                            "Effect loaded at [{}]: {} ({} params)",
                            chain_index, name, param_count
                        );
                        for (i, (pname, min, max)) in params.iter().enumerate() {
                            info!("  [{}] {} (range: {:.2} - {:.2})", i, pname, min, max);
                        }
                        // デフォルト CC マッピングを設定
                        self.param_bridge
                            .setup_effect_mappings(chain_index, param_count, params);
                        info!(
                            "CC 20-27 mapped to {} params",
                            param_count.min(8)
                        );
                    }
                    PluginResponse::InstrumentLoaded { name } => {
                        info!("Instrument loaded: {}", name);
                    }
                    PluginResponse::InstrumentLoadedIntoSlot { slot, name } => {
                        info!("Instrument loaded into slot {}: {}", slot + 1, name);
                    }
                    PluginResponse::SlotSelected { slot, name } => {
                        match name {
                            Some(name) => info!("Slot {} selected: {}", slot + 1, name),
                            None => info!("Slot {} selected: (empty)", slot + 1),
                        }
                    }
                    PluginResponse::Error { message } => {
                        warn!("Plugin error: {}", message);
                    }
                    _ => {}
                }
            }
        }

        // ユニフォームを更新
        self.uniforms.update_time(elapsed, delta);
        self.midi_controller.apply_to_uniforms(&mut self.uniforms);

        // オーディオ解析データを適用
        let use_fake_data = {
            if let Ok(guard) = self.latest_analysis.lock() {
                if let Some(ref analysis) = *guard {
                    self.uniforms.apply_analysis(analysis);
                    self.audio_timestamp = analysis.timestamp;
                    false
                } else {
                    true
                }
            } else {
                true
            }
        };

        // 解析データがない場合はダミーデータ
        if use_fake_data {
            let fake_analysis = AnalysisData {
                rms: 0.3 + 0.2 * (elapsed * 2.0).sin(),
                bass: 0.4 + 0.3 * (elapsed * 1.5).sin(),
                mid: 0.3 + 0.2 * (elapsed * 3.0).sin(),
                high: 0.2 + 0.15 * (elapsed * 5.0).sin(),
                beat_detected: (elapsed * 2.0).fract() < 0.1,
                beat_intensity: 0.5 + 0.3 * (elapsed * 2.0).sin().abs(),
                ..Default::default()
            };
            self.uniforms.apply_analysis(&fake_analysis);
        }

        // レンダラーにユニフォームを適用
        if let Some(ref mut renderer) = self.renderer {
            renderer.update_uniforms(self.uniforms);
            renderer.update_text(&self.audio_filename, self.audio_timestamp);
        }

        self.frame_count += 1;
    }

    /// MIDIイベントをルーティングする
    ///
    /// - ノート → インストゥルメント（プラグインスレッドへ）
    /// - CC 0-7 → ビジュアル（MidiController）
    /// - CC 20+ → プラグインパラメータ（将来のParamBridge拡張用）
    /// - ProgramChange → シーン切替 + プリセット
    fn route_midi_events(&mut self, events: &[cortex_midi::handler::MidiEvent]) {
        use cortex_midi::handler::MidiEvent;

        // MIDI focus が外部（VP/Bastet）のときはハードウェアMIDIを一切処理しない
        // （design/03-midi-focus-model.md）
        if self.midi_focus_external {
            return;
        }

        let mut visual_events = Vec::new();
        let mut plugin_events = Vec::new();

        for event in events {
            match event {
                // ノートイベント → インストゥルメントへ
                MidiEvent::NoteOn { note, .. } => {
                    // シーン切り替え用ノート (C4-B4) はビジュアルにもルーティング
                    if (60..=67).contains(note) {
                        visual_events.push(event.clone());
                    }
                    // インストゥルメントにも常に送信
                    plugin_events.push(event.clone());
                }
                MidiEvent::NoteOff { .. } => {
                    plugin_events.push(event.clone());
                }

                // CC ルーティング
                MidiEvent::ControlChange { control, .. } => {
                    if *control <= VISUAL_CC_MAX {
                        // CC 0-7 → ビジュアル
                        visual_events.push(event.clone());
                    } else {
                        // CC 20-27 → ParamBridge にターゲット値を設定（スムージング）
                        let midi_event = cortex_plugin::MidiEvent::ControlChange {
                            channel: 0,
                            control: *control,
                            value: match event {
                                MidiEvent::ControlChange { value, .. } => *value,
                                _ => 0,
                            },
                        };
                        if self.param_bridge.has_mapping_for(*control) {
                            self.param_bridge.set_target(&midi_event);
                        } else {
                            // マッピングに該当しない CC はプラグインスレッドへ直接転送
                            plugin_events.push(event.clone());
                        }
                    }
                }

                // ピッチベンド → インストゥルメント
                MidiEvent::PitchBend { .. } => {
                    visual_events.push(event.clone());
                    plugin_events.push(event.clone());
                }

                // プログラムチェンジ → シーン切替
                MidiEvent::ProgramChange { .. } => {
                    visual_events.push(event.clone());
                }

                // アフタータッチ → インストゥルメント
                MidiEvent::Aftertouch { .. } => {
                    plugin_events.push(event.clone());
                }

                // ポリ AT（鍵盤ごとの圧力）→ インストゥルメント
                // Keystage の主要な表現手段なので、音源へ確実に渡す
                MidiEvent::PolyAftertouch { .. } => {
                    plugin_events.push(event.clone());
                }
            }
        }

        // ビジュアル用イベントを処理
        self.midi_controller.process_events(&visual_events);

        // プラグインスレッドにMIDIを送信
        if !plugin_events.is_empty() {
            if let Some(ref host) = self.plugin_host {
                if let Err(e) = host.send_midi(plugin_events) {
                    warn!("Failed to send MIDI to plugin: {}", e);
                }
            }
        }
    }

    fn render(&mut self) -> Result<()> {
        if let Some(ref mut renderer) = self.renderer {
            renderer.render().context("Failed to render")?;

            // 録画中ならフレームをキャプチャしてエンコード
            if self.is_recording {
                if let Some(ref mut encoder) = self.video_encoder {
                    match renderer.render_to_buffer() {
                        Ok(rgba_buffer) => {
                            if let Err(e) = encoder.encode_frame(&rgba_buffer) {
                                warn!("Failed to encode frame: {}", e);
                            }
                        }
                        Err(e) => {
                            warn!("Failed to capture frame: {}", e);
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// 録画の開始/停止を切り替え
    fn toggle_recording(&mut self) {
        if self.is_recording {
            // 録画停止
            if let Some(ref mut encoder) = self.video_encoder {
                if let Err(e) = encoder.stop_recording() {
                    warn!("Failed to stop recording: {}", e);
                } else {
                    info!(
                        "Recording stopped: {} frames, {:.1}s",
                        encoder.frame_count(),
                        encoder.elapsed_seconds()
                    );
                }
            }
            self.is_recording = false;
            info!("Recording stopped");
        } else {
            // 録画開始
            let output_path = self.config.output_file.clone().unwrap_or_else(|| {
                let timestamp = chrono::Local::now().format("%Y%m%d_%H%M%S");
                PathBuf::from(format!("output_{}.mp4", timestamp))
            });

            let encoder_config = EncoderConfig {
                width: self.config.width,
                height: self.config.height,
                fps: 60,
                ..Default::default()
            };

            let mut encoder = VideoEncoder::new(encoder_config);
            match encoder.start_recording(&output_path) {
                Ok(()) => {
                    self.video_encoder = Some(encoder);
                    self.is_recording = true;
                    info!("Recording started: {:?}", output_path);
                    if !VideoEncoder::is_ffmpeg_enabled() {
                        warn!("FFmpeg not enabled - recording will use stub encoder");
                    }
                }
                Err(e) => {
                    warn!("Failed to start recording: {}", e);
                }
            }
        }
    }

    fn handle_key(&mut self, key_event: &KeyEvent) {
        // 演奏モード中は音楽キー（press/release 両方）を最優先で処理
        if self.performance_mode && self.handle_musical_key(key_event) {
            return;
        }

        if key_event.state != ElementState::Pressed {
            return;
        }

        match key_event.physical_key {
            PhysicalKey::Code(KeyCode::Tab) => {
                self.toggle_performance_mode();
            }
            PhysicalKey::Code(KeyCode::KeyM) => {
                // MIDI focus 切替（bikeboy ⇄ 外部アプリ/VP）
                self.midi_focus_external = !self.midi_focus_external;
                if self.midi_focus_external {
                    // スタックノート防止: All Notes Off (CC123) を送ってから譲る
                    self.send_note_events(vec![
                        cortex_midi::handler::MidiEvent::ControlChange {
                            channel: 0,
                            control: 123,
                            value: 0,
                        },
                    ]);
                    info!("MIDI focus: external (VP) — ハードウェアMIDIを無視します");
                } else {
                    // focus 復帰: モーターフェーダーを現在のマスターゲインへスナップ
                    let gain = self.master_gain;
                    if let Some(ref mut xtouch) = self.xtouch {
                        let _ = xtouch.project_gain(gain);
                    }
                    info!("MIDI focus: bikeboy — ハードウェアMIDIを処理します");
                }
            }
            PhysicalKey::Code(KeyCode::Space) => {
                self.is_playing = !self.is_playing;
                if let Some(ref host) = self.plugin_host {
                    // ファイル再生のみ停止（ストリームは回し続け、ライブ演奏は継続）
                    let _ = host.set_file_playing(self.is_playing);
                } else if let Some(ref mut player) = self.audio_player {
                    // フォールバック（直接パイプライン）時はストリーム自体を制御
                    if self.is_playing {
                        let _ = player.play();
                    } else {
                        let _ = player.pause();
                    }
                }
                info!(
                    "File playback: {}",
                    if self.is_playing { "started" } else { "paused" }
                );
            }
            PhysicalKey::Code(KeyCode::KeyR) => {
                self.toggle_recording();
            }
            PhysicalKey::Code(KeyCode::KeyO) => {
                // テスト用: 音楽フォルダからファイルを探す
                let home = std::env::var("HOME").unwrap_or_default();
                let test_paths = [
                    format!("{}/Music/test.wav", home),
                    format!("{}/Music/test.mp3", home),
                    format!("{}/Desktop/test.wav", home),
                    format!("{}/Desktop/test.mp3", home),
                ];
                for path_str in &test_paths {
                    let path = PathBuf::from(path_str);
                    if path.exists() {
                        if let Err(e) = self.load_audio_file(&path) {
                            warn!("Failed to load audio: {}", e);
                        }
                        break;
                    }
                }
            }
            PhysicalKey::Code(KeyCode::KeyE) => {
                // AUReverb2 をロード
                if let Some(ref host) = self.plugin_host {
                    if let Some(idx) = host.find_plugin("AUReverb2") {
                        info!("Loading AUReverb2 (index: {})...", idx);
                        if let Err(e) = host.load_effect(idx) {
                            warn!("Failed to load AUReverb2: {}", e);
                        }
                    } else {
                        warn!("AUReverb2 not found in scanned plugins");
                    }
                }
            }
            PhysicalKey::Code(KeyCode::KeyI) => {
                // インストゥルメントを循環選択してロード（Serum 2 等）
                if let Some(ref host) = self.plugin_host {
                    let instruments = host.filter_plugins(PluginType::Instrument);
                    if instruments.is_empty() {
                        warn!("No instrument plugins found");
                    } else {
                        // 初回は Serum を優先選択（以降は循環）
                        if self.instrument_cycle == 0 {
                            if let Some(serum_pos) = instruments
                                .iter()
                                .position(|(_, p)| p.name.contains("Serum"))
                            {
                                self.instrument_cycle = serum_pos;
                            }
                        }
                        let pos = self.instrument_cycle % instruments.len();
                        let (plugin_index, info) = instruments[pos];
                        info!(
                            "Loading instrument [{}/{}]: {}",
                            pos + 1,
                            instruments.len(),
                            info.name
                        );
                        if let Err(e) = host.load_instrument(plugin_index) {
                            warn!("Failed to load instrument: {}", e);
                        }
                        self.instrument_cycle += 1;
                    }
                }
            }
            PhysicalKey::Code(KeyCode::KeyB) => {
                // エフェクトチェーンバイパス切替
                self.effect_bypass = !self.effect_bypass;
                if let Some(ref host) = self.plugin_host {
                    let _ = host.send_command(PluginCommand::SetAllEffectBypass {
                        bypass: self.effect_bypass,
                    });
                }
                info!(
                    "Effect chain bypass: {}",
                    if self.effect_bypass {
                        "ON (dry)"
                    } else {
                        "OFF (wet)"
                    }
                );
            }
            PhysicalKey::Code(KeyCode::Escape) => {
                info!("Quit requested");
            }
            // 数字キー 1-8 = インストゥルメントスロット選択（LPD8 パッドと同じ操作系。
            // design/05 §7 S-A。旧シーン切替は WGSL 未参照で無機能だったため転用）
            PhysicalKey::Code(code @ (KeyCode::Digit1
            | KeyCode::Digit2
            | KeyCode::Digit3
            | KeyCode::Digit4
            | KeyCode::Digit5
            | KeyCode::Digit6
            | KeyCode::Digit7
            | KeyCode::Digit8)) => {
                let slot = match code {
                    KeyCode::Digit1 => 0,
                    KeyCode::Digit2 => 1,
                    KeyCode::Digit3 => 2,
                    KeyCode::Digit4 => 3,
                    KeyCode::Digit5 => 4,
                    KeyCode::Digit6 => 5,
                    KeyCode::Digit7 => 6,
                    KeyCode::Digit8 => 7,
                    _ => unreachable!(),
                };
                if let Some(ref host) = self.plugin_host {
                    if let Err(e) = host.select_slot(slot) {
                        warn!("Failed to select slot {}: {}", slot, e);
                    }
                }
            }
            _ => {}
        }
    }

    /// PCキーをMIDIノートオフセットに変換（GarageBand式 musical typing）
    ///
    /// A行=白鍵、W行=黒鍵。Aキーが基準ノート（デフォルト C4）。
    /// ```text
    ///   W E   T Y U   O P
    ///  A S D F G H J K L ;
    ///  C D E F G A B C D E
    /// ```
    fn musical_key_offset(code: KeyCode) -> Option<u8> {
        let offset = match code {
            KeyCode::KeyA => 0,        // C
            KeyCode::KeyW => 1,        // C#
            KeyCode::KeyS => 2,        // D
            KeyCode::KeyE => 3,        // D#
            KeyCode::KeyD => 4,        // E
            KeyCode::KeyF => 5,        // F
            KeyCode::KeyT => 6,        // F#
            KeyCode::KeyG => 7,        // G
            KeyCode::KeyY => 8,        // G#
            KeyCode::KeyH => 9,        // A
            KeyCode::KeyU => 10,       // A#
            KeyCode::KeyJ => 11,       // B
            KeyCode::KeyK => 12,       // C+1oct
            KeyCode::KeyO => 13,       // C#+1oct
            KeyCode::KeyL => 14,       // D+1oct
            KeyCode::KeyP => 15,       // D#+1oct
            KeyCode::Semicolon => 16,  // E+1oct
            _ => return None,
        };
        Some(offset)
    }

    /// 演奏モードのキーイベント処理。処理（消費）した場合 true を返す。
    fn handle_musical_key(&mut self, key_event: &KeyEvent) -> bool {
        let PhysicalKey::Code(code) = key_event.physical_key else {
            return false;
        };

        // オクターブ変更（押下時のみ、リピート無視）
        if key_event.state == ElementState::Pressed && matches!(code, KeyCode::KeyZ | KeyCode::KeyX)
        {
            if !key_event.repeat {
                self.keyboard_base_note = match code {
                    KeyCode::KeyZ => self.keyboard_base_note.saturating_sub(12).max(12),
                    _ => (self.keyboard_base_note + 12).min(96),
                };
                info!(
                    "Keyboard octave: base note {} (C{})",
                    self.keyboard_base_note,
                    self.keyboard_base_note as i32 / 12 - 1
                );
            }
            return true;
        }

        let Some(offset) = Self::musical_key_offset(code) else {
            return false;
        };

        match key_event.state {
            ElementState::Pressed => {
                // キーリピートと多重押下は無視（消費はする）
                if key_event.repeat || self.pressed_note_keys.contains_key(&code) {
                    return true;
                }
                let note = self.keyboard_base_note.saturating_add(offset).min(127);
                self.pressed_note_keys.insert(code, note);
                self.send_note_events(vec![cortex_midi::handler::MidiEvent::NoteOn {
                    channel: 0,
                    note,
                    velocity: 100,
                }]);
            }
            ElementState::Released => {
                // 押下時に記録したノート番号で消音する
                // （途中でオクターブを変えてもノートが残らない）
                if let Some(note) = self.pressed_note_keys.remove(&code) {
                    self.send_note_events(vec![cortex_midi::handler::MidiEvent::NoteOff {
                        channel: 0,
                        note,
                        velocity: 64,
                    }]);
                }
            }
        }
        true
    }

    /// 演奏モードを切り替える。OFF時は押しっぱなしのノートを全消音する。
    fn toggle_performance_mode(&mut self) {
        self.performance_mode = !self.performance_mode;

        if !self.performance_mode && !self.pressed_note_keys.is_empty() {
            let note_offs: Vec<_> = self
                .pressed_note_keys
                .drain()
                .map(|(_, note)| cortex_midi::handler::MidiEvent::NoteOff {
                    channel: 0,
                    note,
                    velocity: 64,
                })
                .collect();
            self.send_note_events(note_offs);
        }

        if self.performance_mode {
            info!("Performance mode: ON — A行=白鍵 W行=黒鍵 Z/X=オクターブ Tab=解除");
        } else {
            info!("Performance mode: OFF");
        }
    }

    /// ノートイベントをプラグインスレッドへ直接送信する
    /// （updateループを待たないため、キー押下から最小遅延で発音する）
    fn send_note_events(&self, events: Vec<cortex_midi::handler::MidiEvent>) {
        if let Some(ref host) = self.plugin_host {
            if let Err(e) = host.send_midi(events) {
                warn!("Failed to send note events: {}", e);
            }
        }
    }

    fn handle_dropped_file(&mut self, path: PathBuf) {
        info!("File dropped: {:?}", path);
        if let Err(e) = self.load_audio_file(&path) {
            warn!("Failed to load dropped file: {}", e);
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }

        let window_attributes = WindowAttributes::default()
            .with_title("bikeboy-cortex")
            .with_inner_size(winit::dpi::PhysicalSize::new(
                self.config.width,
                self.config.height,
            ));

        let window = Arc::new(
            event_loop
                .create_window(window_attributes)
                .expect("Failed to create window"),
        );

        self.window = Some(window.clone());

        // 非同期でレンダラーを初期化
        pollster::block_on(async {
            if let Err(e) = self.initialize_renderer(window).await {
                tracing::error!("Failed to initialize renderer: {}", e);
            }
        });

        // MIDI初期化
        if let Err(e) = self.initialize_midi() {
            warn!("MIDI initialization failed: {}", e);
        }

        // オーディオ初期化（プラグインパイプライン含む）
        if let Err(e) = self.initialize_audio() {
            warn!("Audio initialization failed: {}", e);
        }

        // オーディオファイルを自動ロード
        if let Some(ref audio_path) = self.config.audio_file.clone() {
            if audio_path.exists() {
                info!("Loading audio file: {:?}", audio_path);
                if let Err(e) = self.load_audio_file(audio_path) {
                    warn!("Failed to load audio file: {}", e);
                } else {
                    // 自動再生開始
                    self.is_playing = true;
                    if let Some(ref mut player) = self.audio_player {
                        let _ = player.play();
                    }
                    info!("Playback started automatically");
                }
            } else {
                warn!("Audio file not found: {:?}", audio_path);
            }
        }

        info!("Application initialized");
        info!("Keys: Space=ファイル再生/停止 | Tab=演奏モード(A行=白鍵 W行=黒鍵 Z/X=oct) | I=音源切替 | M=MIDIフォーカス切替 | E=リバーブ | B=バイパス | R=録画 | Esc=終了");
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _id: WindowId,
        event: WindowEvent,
    ) {
        match event {
            WindowEvent::CloseRequested => {
                info!("Window close requested");
                // プラグインシステムをシャットダウン
                if let Some(ref host) = self.plugin_host {
                    let _ = host.shutdown();
                }
                event_loop.exit();
            }
            WindowEvent::Resized(size) => {
                if size.width > 0 && size.height > 0 {
                    if let Some(ref mut renderer) = self.renderer {
                        renderer.resize(size.width, size.height);
                    }
                    self.uniforms.resolution = [size.width as f32, size.height as f32];
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                self.handle_key(&event);
                if event.state == ElementState::Pressed {
                    if let PhysicalKey::Code(KeyCode::Escape) = event.physical_key {
                        // プラグインシステムをシャットダウン
                        if let Some(ref host) = self.plugin_host {
                            let _ = host.shutdown();
                        }
                        event_loop.exit();
                    }
                }
            }
            WindowEvent::DroppedFile(path) => {
                self.handle_dropped_file(path);
            }
            WindowEvent::RedrawRequested => {
                self.update();
                if let Err(e) = self.render() {
                    tracing::error!("Render error: {}", e);
                }
                if let Some(ref window) = self.window {
                    window.request_redraw();
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(ref window) = self.window {
            window.request_redraw();
        }
    }
}

fn main() -> Result<()> {
    // ロギング初期化
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("cortex=info".parse().unwrap())
                .add_directive("wgpu=warn".parse().unwrap()),
        )
        .init();

    info!("bikeboy-cortex starting...");

    // コマンドライン引数をパース
    let args: Vec<String> = std::env::args().collect();
    let audio_file = if args.len() > 1 {
        Some(PathBuf::from(&args[1]))
    } else {
        // デフォルト: ./assets/Own it.wav
        Some(PathBuf::from("./assets/Narrow Down.wav"))
    };

    let config = AppConfig {
        audio_file,
        ..AppConfig::default()
    };

    // イベントループ作成
    let event_loop = EventLoop::new().context("Failed to create event loop")?;
    event_loop.set_control_flow(ControlFlow::Poll);

    // アプリケーション作成と実行
    let mut app = App::new(config);
    event_loop.run_app(&mut app).context("Event loop error")?;

    info!("Application terminated");
    Ok(())
}
