//! プラグインホスト
//!
//! メインスレッド側の PluginHost とプラグインスレッド側の PluginProcessor を提供する。
//! rack::Plugin は Send + !Sync なので、全プラグインインスタンスを1つの専用スレッドが所有する。
//!
//! REQ-PLUGIN-007: プラグインホスト・プロセッサ

use crossbeam_channel::{bounded, Receiver, Sender};
use rack::prelude::*;

use cortex_types::AudioFrame;

use crate::effect_chain::EffectChain;
use crate::error::{PluginError, PluginResult};
use crate::midi_convert::MidiEvent;
use crate::mixer::AudioMixer;

/// ホスティング不適合プラグインの deny list（名前の部分一致）
///
/// Splice Sounds は AU インストゥルメントとして登録されるが実体はサンプル
/// ブラウザで、ロードすると main thread の RunLoop に登録したコールバック内で
/// `splice::MessageBus` が null mutex を lock して SIGSEGV する
/// （2026-07-30 実機クラッシュ。cortex 側では防げないプラグイン内部のバグ）。
/// ライブの価値基準は「確実に動く」（design/05 §1）— 全ロード経路で弾く。
const HOSTING_DENY_LIST: &[&str] = &["Splice"];

/// deny list に該当するか
fn is_deny_listed(name: &str) -> bool {
    HOSTING_DENY_LIST.iter().any(|d| name.contains(d))
}

/// メインスレッドからプラグインスレッドへのコマンド
#[derive(Debug)]
pub enum PluginCommand {
    /// エフェクトをチェーン末尾に追加
    LoadEffect {
        /// プラグインのインデックス（スキャン結果内）
        plugin_index: usize,
    },
    /// エフェクトチェーンからエフェクトを削除
    RemoveEffect {
        /// チェーン内のインデックス
        chain_index: usize,
    },
    /// インストゥルメントを選択中のスロットにロード
    LoadInstrument {
        /// プラグインのインデックス（スキャン結果内）
        plugin_index: usize,
    },
    /// インストゥルメントを指定スロットにロード（design/05 §7 S-A）
    LoadInstrumentIntoSlot {
        /// スロットインデックス（0-7）
        slot: usize,
        /// プラグインのインデックス（スキャン結果内）
        plugin_index: usize,
    },
    /// スロットを選択（LPD8 パッド 1-8 に対応）
    ///
    /// 旧選択スロットはリリースを鳴らし切ってから process 対象から外れる。
    SelectSlot {
        /// スロットインデックス（0-7）
        slot: usize,
    },
    /// 選択中のスロットからインストゥルメントをアンロード
    UnloadInstrument,
    /// MIDI イベントをインストゥルメントに送信
    SendMidi { events: Vec<MidiEvent> },
    /// エフェクトのパラメータを設定
    SetEffectParam {
        chain_index: usize,
        param_index: usize,
        value: f32,
    },
    /// インストゥルメントのパラメータを設定
    SetInstrumentParam { param_index: usize, value: f32 },
    /// エフェクトのバイパスを設定
    SetEffectBypass { chain_index: usize, bypass: bool },
    /// 全エフェクトのバイパスを設定
    SetAllEffectBypass { bypass: bool },
    /// ファイル再生の有効/無効を設定
    ///
    /// false の場合、デコーダーからのフレームを取り込まず（＝ファイル再生は
    /// バックプレッシャーで停止）、無音フレームを生成してインストゥルメントを
    /// 駆動し続ける。
    SetFilePlaying { playing: bool },
    /// ファイル再生ゲインを設定
    SetFileGain { gain: f32 },
    /// マスターゲインを設定
    SetMasterGain { gain: f32 },
    /// プロセッサを停止
    Shutdown,
}

/// プラグインスレッドからメインスレッドへの応答
#[derive(Debug)]
pub enum PluginResponse {
    /// エフェクトロード完了
    EffectLoaded {
        chain_index: usize,
        name: String,
        /// パラメータ数
        param_count: usize,
        /// パラメータ情報: (name, min, max)
        params: Vec<(String, f32, f32)>,
    },
    /// エフェクト削除完了
    EffectRemoved { chain_index: usize },
    /// インストゥルメントロード完了
    InstrumentLoaded { name: String },
    /// スロットへのインストゥルメントロード完了
    InstrumentLoadedIntoSlot { slot: usize, name: String },
    /// スロット選択完了
    SlotSelected {
        slot: usize,
        /// 選択先スロットのプラグイン名（空スロットなら None）
        name: Option<String>,
    },
    /// インストゥルメントアンロード完了
    InstrumentUnloaded,
    /// エラー発生
    Error { message: String },
}

/// プラグインプロセッサ — プラグインスレッドで動作
///
/// 全プラグインインスタンスを所有し、オーディオ処理を行う。
pub struct PluginProcessor {
    /// プラグインスキャナー
    scanner: Scanner,
    /// スキャン済みプラグインリスト
    plugins: Vec<PluginInfo>,
    /// エフェクトチェーン
    effect_chain: EffectChain,
    /// オーディオミキサー（インストゥルメント含む）
    mixer: AudioMixer,
    /// コマンド受信チャンネル
    command_rx: Receiver<PluginCommand>,
    /// レスポンス送信チャンネル
    response_tx: Sender<PluginResponse>,
    /// 入力フレーム受信チャンネル
    frame_rx: Receiver<AudioFrame>,
    /// 処理済みフレーム送信チャンネル
    processed_tx: Sender<AudioFrame>,
    /// サンプルレート
    sample_rate: f64,
    /// 最大バッファサイズ
    max_buffer_size: usize,
    /// ファイル再生が有効か（false ならライブ演奏専用クロックで動作）
    file_playing: bool,
    /// ライブ生成フレーム用の連続タイムスタンプ（秒）
    live_timestamp: f64,
}

impl PluginProcessor {
    /// ライブモードで生成する無音フレームのサンプル数
    ///
    /// 512 samples @ 48kHz ≈ 10.7ms。processed チャンネル容量（PROCESSED_QUEUE_CAP）
    /// との積が演奏レイテンシの上限になる。
    const LIVE_BLOCK_FRAMES: usize = 512;

    /// プロセッサのメインループを実行
    ///
    /// このメソッドはプラグインスレッドで呼び出される。
    /// ファイル再生中は frame_rx のフレームを、それ以外は自前生成した無音フレームを
    /// ベースにプラグイン処理を行い、processed_tx へ送信する。
    /// 送信は bounded チャンネルのバックプレッシャーでペーシングされる
    /// （cpal の消費速度 = 実時間に同期する）。
    pub fn run(mut self) {
        tracing::info!("PluginProcessor started (live clock mode)");

        loop {
            // コマンドを先にドレイン（ノンブロッキング）
            if !self.process_commands() {
                break; // Shutdown コマンド受信
            }

            // ベースフレームを取得（ファイル or 無音）
            let Some(mut frame) = self.next_base_frame() else {
                tracing::info!("frame_rx disconnected, stopping");
                break;
            };

            // max_buffer_size 以下のチャンクに分割して処理する。
            // デコーダーのフレーム（symphonia のパケット単位、例: WAV で 1152）は
            // max_buffer_size を超えることがあり、そのまま渡すと mixer の
            // スクラッチバッファ範囲外アクセスや AU の最大レンダーサイズ違反になる。
            let num_frames = frame.len();
            let mut offset = 0;
            while offset < num_frames {
                let end = (offset + self.max_buffer_size).min(num_frames);
                let chunk = end - offset;

                // ミキサー処理（ファイル再生 + インストゥルメント）
                self.mixer.process(
                    &mut frame.left[offset..end],
                    &mut frame.right[offset..end],
                    chunk,
                );

                // エフェクトチェーン処理
                self.effect_chain.process(
                    &mut frame.left[offset..end],
                    &mut frame.right[offset..end],
                    chunk,
                );

                offset = end;
            }

            // 処理済みフレームを送信（バックプレッシャーでペーシング）
            match self
                .processed_tx
                .send_timeout(frame, std::time::Duration::from_millis(100))
            {
                Ok(()) => {}
                Err(crossbeam_channel::SendTimeoutError::Timeout(_)) => {
                    // cpal が消費していない（ストリーム停止中など）。
                    // フレームを破棄してコマンド処理に戻る（シャットダウンをブロックしない）
                    continue;
                }
                Err(crossbeam_channel::SendTimeoutError::Disconnected(_)) => {
                    tracing::warn!("processed_tx disconnected, stopping");
                    break;
                }
            }
        }

        tracing::info!("PluginProcessor stopped");
    }

    /// 処理のベースとなるフレームを取得する
    ///
    /// - ファイル再生中: デコーダーのフレームを短時間待って取得
    ///   （デコーダーは実時間より速いため、通常は即座に取得できる）
    /// - ファイル停止中 or デコーダーが空（EOF等）: 無音フレームを生成して
    ///   インストゥルメントのライブ演奏クロックを維持する
    ///
    /// frame_rx が切断された場合のみ None を返す。
    fn next_base_frame(&mut self) -> Option<AudioFrame> {
        if self.file_playing {
            match self
                .frame_rx
                .recv_timeout(std::time::Duration::from_millis(5))
            {
                Ok(frame) => {
                    // ファイルのタイムスタンプにライブクロックを追従させる
                    self.live_timestamp =
                        frame.timestamp + frame.len() as f64 / frame.sample_rate.max(1) as f64;
                    return Some(frame);
                }
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                    // ファイル未ロード or EOF → 無音フレームにフォールバック
                }
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                    return None;
                }
            }
        }

        // ライブ演奏用の無音フレームを生成
        let frame = AudioFrame::new(
            vec![0.0; Self::LIVE_BLOCK_FRAMES],
            vec![0.0; Self::LIVE_BLOCK_FRAMES],
            self.sample_rate as u32,
            self.live_timestamp,
        );
        self.live_timestamp += Self::LIVE_BLOCK_FRAMES as f64 / self.sample_rate;
        Some(frame)
    }

    /// コマンドをドレインして処理する
    ///
    /// Shutdown コマンドを受信した場合は false を返す。
    fn process_commands(&mut self) -> bool {
        while let Ok(cmd) = self.command_rx.try_recv() {
            match cmd {
                PluginCommand::Shutdown => return false,

                PluginCommand::LoadEffect { plugin_index } => {
                    self.handle_load_effect(plugin_index);
                }
                PluginCommand::RemoveEffect { chain_index } => {
                    if self.effect_chain.remove(chain_index).is_some() {
                        let _ = self
                            .response_tx
                            .try_send(PluginResponse::EffectRemoved { chain_index });
                    }
                }
                PluginCommand::LoadInstrument { plugin_index } => {
                    let slot = self.mixer.rack().selected_index();
                    self.handle_load_instrument(slot, plugin_index);
                }
                PluginCommand::LoadInstrumentIntoSlot { slot, plugin_index } => {
                    self.handle_load_instrument(slot, plugin_index);
                }
                PluginCommand::SelectSlot { slot } => {
                    self.mixer.rack_mut().select(slot);
                    let name = self
                        .mixer
                        .rack()
                        .selected_slot()
                        .slot()
                        .map(|s| s.name().to_string());
                    let _ = self
                        .response_tx
                        .try_send(PluginResponse::SlotSelected { slot, name });
                }
                PluginCommand::UnloadInstrument => {
                    self.mixer.rack_mut().selected_slot_mut().unload();
                    let _ = self
                        .response_tx
                        .try_send(PluginResponse::InstrumentUnloaded);
                }
                PluginCommand::SendMidi { events } => {
                    if let Err(e) = self.mixer.rack_mut().send_midi(&events) {
                        tracing::warn!("MIDI send error: {}", e);
                    }
                }
                PluginCommand::SetEffectParam {
                    chain_index,
                    param_index,
                    value,
                } => {
                    if let Some(slot) = self.effect_chain.get_mut(chain_index) {
                        if let Err(e) = slot.set_parameter(param_index, value) {
                            tracing::warn!("Effect param error: {}", e);
                        }
                    }
                }
                PluginCommand::SetInstrumentParam { param_index, value } => {
                    if let Some(slot) = self.mixer.rack_mut().selected_slot_mut().slot_mut() {
                        if let Err(e) = slot.set_parameter(param_index, value) {
                            tracing::warn!("Instrument param error: {}", e);
                        }
                    }
                }
                PluginCommand::SetEffectBypass {
                    chain_index,
                    bypass,
                } => {
                    if let Some(slot) = self.effect_chain.get_mut(chain_index) {
                        slot.set_bypass(bypass);
                    }
                }
                PluginCommand::SetAllEffectBypass { bypass } => {
                    self.effect_chain.set_all_bypass(bypass);
                }
                PluginCommand::SetFilePlaying { playing } => {
                    self.file_playing = playing;
                    tracing::info!(
                        "File playback: {}",
                        if playing {
                            "enabled"
                        } else {
                            "paused (live mode)"
                        }
                    );
                }
                PluginCommand::SetFileGain { gain } => {
                    self.mixer.set_file_gain(gain);
                }
                PluginCommand::SetMasterGain { gain } => {
                    self.mixer.set_master_gain(gain);
                }
            }
        }
        true
    }

    fn handle_load_effect(&mut self, plugin_index: usize) {
        if plugin_index >= self.plugins.len() {
            let _ = self.response_tx.try_send(PluginResponse::Error {
                message: format!("Plugin index {} out of range", plugin_index),
            });
            return;
        }

        if is_deny_listed(&self.plugins[plugin_index].name) {
            let _ = self.response_tx.try_send(PluginResponse::Error {
                message: format!(
                    "{} はホスティング不適合のためロードしません（deny list）",
                    self.plugins[plugin_index].name
                ),
            });
            return;
        }

        let info = &self.plugins[plugin_index];
        match self
            .effect_chain
            .push(&self.scanner, info, self.sample_rate, self.max_buffer_size)
        {
            Ok(()) => {
                let chain_index = self.effect_chain.len() - 1;

                // ロードしたスロットからパラメータ情報を収集
                let (param_count, params) = if let Some(slot) = self.effect_chain.get(chain_index) {
                    let count = slot.parameter_count();
                    let params: Vec<(String, f32, f32)> = (0..count)
                        .filter_map(|i| {
                            slot.parameter_info(i)
                                .ok()
                                .map(|p| (p.name.clone(), p.min, p.max))
                        })
                        .collect();
                    (count, params)
                } else {
                    (0, Vec::new())
                };

                let _ = self.response_tx.try_send(PluginResponse::EffectLoaded {
                    chain_index,
                    name: info.name.clone(),
                    param_count,
                    params,
                });
            }
            Err(e) => {
                let _ = self.response_tx.try_send(PluginResponse::Error {
                    message: format!("Failed to load effect: {}", e),
                });
            }
        }
    }

    fn handle_load_instrument(&mut self, slot: usize, plugin_index: usize) {
        if plugin_index >= self.plugins.len() {
            let _ = self.response_tx.try_send(PluginResponse::Error {
                message: format!("Plugin index {} out of range", plugin_index),
            });
            return;
        }

        if is_deny_listed(&self.plugins[plugin_index].name) {
            let _ = self.response_tx.try_send(PluginResponse::Error {
                message: format!(
                    "{} はホスティング不適合のためロードしません（deny list）",
                    self.plugins[plugin_index].name
                ),
            });
            return;
        }

        let info = &self.plugins[plugin_index];
        match self.mixer.rack_mut().load_into(
            slot,
            &self.scanner,
            info,
            self.sample_rate,
            self.max_buffer_size,
        ) {
            Ok(()) => {
                // 選択中スロットへのロードは従来の応答、それ以外はスロット付き応答
                let resp = if slot == self.mixer.rack().selected_index() {
                    PluginResponse::InstrumentLoaded {
                        name: info.name.clone(),
                    }
                } else {
                    PluginResponse::InstrumentLoadedIntoSlot {
                        slot,
                        name: info.name.clone(),
                    }
                };
                let _ = self.response_tx.try_send(resp);
            }
            Err(e) => {
                let _ = self.response_tx.try_send(PluginResponse::Error {
                    message: format!("Failed to load instrument into slot {}: {}", slot, e),
                });
            }
        }
    }
}

/// プラグインホスト — メインスレッドで動作
///
/// プラグインスキャン、コマンド送信、レスポンスポーリングを提供する。
pub struct PluginHost {
    /// スキャン済みプラグインリスト
    plugins: Vec<PluginInfo>,
    /// コマンド送信チャンネル
    command_tx: Sender<PluginCommand>,
    /// レスポンス受信チャンネル
    response_rx: Receiver<PluginResponse>,
}

impl PluginHost {
    /// processed チャンネルの容量（演奏レイテンシの上限を決める）
    const PROCESSED_QUEUE_CAP: usize = 4;

    /// PluginHost と PluginProcessor のペアを作成する
    ///
    /// # Returns
    /// - `(PluginHost, PluginProcessor)` — Host はメインスレッド、Processor はプラグインスレッドで使用
    /// - `frame_tx` — デコーダーからのフレーム送信先
    /// - `processed_rx` — 処理済みフレームの受信元（cpal に接続）
    pub fn new(
        sample_rate: f64,
        max_buffer_size: usize,
    ) -> PluginResult<(
        Self,
        PluginProcessor,
        Sender<AudioFrame>,
        Receiver<AudioFrame>,
    )> {
        let scanner = Scanner::new().map_err(|e| PluginError::Scanner(e.to_string()))?;
        let plugins = scanner
            .scan()
            .map_err(|e| PluginError::Scanner(e.to_string()))?;

        tracing::info!("Scanned {} plugins", plugins.len());

        let (command_tx, command_rx) = bounded(64);
        let (response_tx, response_rx) = bounded(32);
        let (frame_tx, frame_rx) = bounded::<AudioFrame>(32);
        // processed チャンネルは演奏レイテンシに直結するため小さく保つ
        // （4 × 512 samples @ 48kHz ≈ 43ms が上限）
        let (processed_tx, processed_rx) = bounded::<AudioFrame>(Self::PROCESSED_QUEUE_CAP);

        let host = PluginHost {
            plugins: plugins.clone(),
            command_tx,
            response_rx,
        };

        let processor = PluginProcessor {
            scanner,
            plugins,
            effect_chain: EffectChain::new(),
            mixer: AudioMixer::new(sample_rate, max_buffer_size),
            command_rx,
            response_tx,
            frame_rx,
            processed_tx,
            sample_rate,
            max_buffer_size,
            file_playing: true,
            live_timestamp: 0.0,
        };

        Ok((host, processor, frame_tx, processed_rx))
    }

    /// コマンドを送信
    pub fn send_command(&self, command: PluginCommand) -> PluginResult<()> {
        self.command_tx
            .send(command)
            .map_err(|e| PluginError::Channel(format!("Command send failed: {}", e)))
    }

    /// レスポンスをポーリング
    pub fn poll_responses(&self) -> Vec<PluginResponse> {
        let mut responses = Vec::new();
        while let Ok(resp) = self.response_rx.try_recv() {
            responses.push(resp);
        }
        responses
    }

    /// スキャン済みプラグインリスト
    pub fn plugins(&self) -> &[PluginInfo] {
        &self.plugins
    }

    /// 名前でプラグインを検索
    pub fn find_plugin(&self, name: &str) -> Option<usize> {
        self.plugins.iter().position(|p| p.name.contains(name))
    }

    /// タイプでプラグインをフィルタ
    ///
    /// ホスティング不適合の deny list（`HOSTING_DENY_LIST`）該当は除外する。
    /// `I` キーの循環選択など「一覧から選ぶ」経路がここを通るため、
    /// 不適合プラグインは候補にも出ない。
    pub fn filter_plugins(&self, plugin_type: PluginType) -> Vec<(usize, &PluginInfo)> {
        self.plugins
            .iter()
            .enumerate()
            .filter(|(_, p)| p.plugin_type == plugin_type && !is_deny_listed(&p.name))
            .collect()
    }

    /// エフェクトをロード（ヘルパー）
    pub fn load_effect(&self, plugin_index: usize) -> PluginResult<()> {
        self.send_command(PluginCommand::LoadEffect { plugin_index })
    }

    /// インストゥルメントを選択中のスロットにロード（ヘルパー）
    pub fn load_instrument(&self, plugin_index: usize) -> PluginResult<()> {
        self.send_command(PluginCommand::LoadInstrument { plugin_index })
    }

    /// インストゥルメントを指定スロットにロード（ヘルパー）
    pub fn load_instrument_into_slot(&self, slot: usize, plugin_index: usize) -> PluginResult<()> {
        self.send_command(PluginCommand::LoadInstrumentIntoSlot { slot, plugin_index })
    }

    /// スロットを選択（ヘルパー。LPD8 パッド 1-8 に対応）
    pub fn select_slot(&self, slot: usize) -> PluginResult<()> {
        self.send_command(PluginCommand::SelectSlot { slot })
    }

    /// MIDI イベントを送信（ヘルパー）
    pub fn send_midi(&self, events: Vec<MidiEvent>) -> PluginResult<()> {
        self.send_command(PluginCommand::SendMidi { events })
    }

    /// ファイル再生の有効/無効を設定（ヘルパー）
    ///
    /// 無効にしてもインストゥルメントのライブ演奏は継続する。
    pub fn set_file_playing(&self, playing: bool) -> PluginResult<()> {
        self.send_command(PluginCommand::SetFilePlaying { playing })
    }

    /// シャットダウンを送信
    pub fn shutdown(&self) -> PluginResult<()> {
        self.send_command(PluginCommand::Shutdown)
    }
}

impl Drop for PluginHost {
    fn drop(&mut self) {
        let _ = self.command_tx.send(PluginCommand::Shutdown);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deny_list_matches_splice() {
        assert!(is_deny_listed("Splice Sounds"));
        assert!(is_deny_listed("Splice Sounds Listener"));
    }

    #[test]
    fn test_deny_list_passes_instruments() {
        assert!(!is_deny_listed("Serum 2"));
        assert!(!is_deny_listed("KORG: Memphis (MS-20)"));
        assert!(!is_deny_listed("KORG: London (Drum)"));
    }

    #[test]
    fn test_filter_plugins_excludes_deny_listed() {
        // 実機スキャンに Splice が存在する場合、候補一覧に出ないこと
        let Ok((host, _proc, _tx, _rx)) = PluginHost::new(48000.0, 512) else {
            eprintln!("scanner unavailable, skipping");
            return;
        };
        for ty in [PluginType::Instrument, PluginType::Effect] {
            for (_, info) in host.filter_plugins(ty) {
                assert!(
                    !is_deny_listed(&info.name),
                    "deny-listed plugin leaked into filter_plugins: {}",
                    info.name
                );
            }
        }
    }
}
