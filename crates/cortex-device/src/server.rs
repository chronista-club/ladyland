//! MARU TCP サーバー
//!
//! port 9876 で MARU デバイスからの接続を待ち受け、
//! Wire Protocol に基づいてメッセージを処理する。

use std::io::BufReader;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use tracing::{error, info, warn};

use crate::protocol::{self, DeviceMessage, HostMessage, ModeId};
use crate::volume;

/// デフォルトポート
const DEFAULT_PORT: u16 = 9876;
/// 1回転あたりの音量変化 (0.0〜1.0 スケール)
/// 0.02 = 2% 刻み
const VOLUME_STEP: f32 = 0.02;

/// MARU サーバー
pub struct MaruServer {
    port: u16,
    running: Arc<AtomicBool>,
}

impl MaruServer {
    pub fn new() -> Self {
        Self {
            port: DEFAULT_PORT,
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn with_port(mut self, port: u16) -> Self {
        self.port = port;
        self
    }

    /// サーバーを別スレッドで起動
    ///
    /// 戻り値の `MaruHandle` で停止を制御できる。
    pub fn start(self) -> MaruHandle {
        let running = self.running.clone();
        running.store(true, Ordering::SeqCst);

        let handle = thread::Builder::new()
            .name("maru-server".into())
            .spawn(move || {
                self.run();
            })
            .expect("failed to spawn maru-server thread");

        MaruHandle {
            running,
            thread: Some(handle),
        }
    }

    fn run(&self) {
        let addr = format!("0.0.0.0:{}", self.port);
        let listener = match TcpListener::bind(&addr) {
            Ok(l) => {
                info!("MARU server listening on {}", addr);
                l
            }
            Err(e) => {
                error!("MARU server bind failed: {}", e);
                return;
            }
        };

        // ノンブロッキングで accept（停止チェックのため）
        listener
            .set_nonblocking(true)
            .expect("cannot set non-blocking");

        while self.running.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, addr)) => {
                    info!("MARU device connected: {}", addr);
                    // クライアントはブロッキングで処理
                    stream.set_nonblocking(false).ok();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(30)))
                        .ok();
                    self.handle_client(stream);
                    info!("MARU device disconnected: {}", addr);
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // 接続待ち
                    thread::sleep(Duration::from_millis(100));
                }
                Err(e) => {
                    error!("MARU accept error: {}", e);
                    thread::sleep(Duration::from_millis(100));
                }
            }
        }

        info!("MARU server stopped");
    }

    fn handle_client(&self, stream: TcpStream) {
        let mut writer = stream.try_clone().expect("failed to clone stream");
        let mut reader = BufReader::new(stream);

        loop {
            if !self.running.load(Ordering::SeqCst) {
                break;
            }

            let msg = match protocol::read_frame(&mut reader) {
                Ok(Some(msg)) => msg,
                Ok(None) => break, // 接続終了
                Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    continue; // タイムアウトは正常（heartbeat 待ち）
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    continue;
                }
                Err(e) => {
                    warn!("MARU read error: {}", e);
                    break;
                }
            };

            match msg {
                DeviceMessage::Hello {
                    fw_version,
                    device_id,
                } => {
                    info!(
                        "MARU Hello: fw=v{}, id={:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
                        fw_version,
                        device_id[0],
                        device_id[1],
                        device_id[2],
                        device_id[3],
                        device_id[4],
                        device_id[5],
                    );
                    // Welcome 応答
                    if let Err(e) = protocol::write_frame(&mut writer, &HostMessage::Welcome) {
                        error!("MARU write Welcome failed: {}", e);
                        break;
                    }
                    // 初期状態送信
                    if let Err(e) = send_volume_state(&mut writer) {
                        error!("MARU write initial state failed: {}", e);
                        break;
                    }
                }

                DeviceMessage::ModeChange { mode_id } => {
                    info!("MARU ModeChange: 0x{:02X}", mode_id);
                    if mode_id == ModeId::Volume as u8 {
                        if let Err(e) = send_volume_state(&mut writer) {
                            error!("MARU write state failed: {}", e);
                            break;
                        }
                    }
                }

                DeviceMessage::RotaryDelta { mode_id, delta } => {
                    if mode_id == ModeId::Volume as u8 {
                        // Batch: drain any queued rotary deltas
                        let mut total_delta = delta as i16;
                        reader.get_ref().set_read_timeout(Some(Duration::from_millis(5))).ok();
                        loop {
                            match protocol::read_frame(&mut reader) {
                                Ok(Some(DeviceMessage::RotaryDelta { mode_id: mid, delta: d }))
                                    if mid == ModeId::Volume as u8 =>
                                {
                                    total_delta += d as i16;
                                }
                                _ => break,
                            }
                        }
                        reader.get_ref().set_read_timeout(Some(Duration::from_secs(30))).ok();

                        let new_vol = volume::adjust_volume(
                            total_delta.clamp(-128, 127) as i8,
                            VOLUME_STEP,
                        );
                        info!("MARU Volume: delta={}, new={:.1}%", total_delta, new_vol * 100.0);
                        if let Err(e) = send_volume_state(&mut writer) {
                            error!("MARU write state failed: {}", e);
                            break;
                        }
                    }
                }

                DeviceMessage::ButtonAction { mode_id, action } => {
                    if mode_id == ModeId::Volume as u8 {
                        match action {
                            0 => {
                                // 短押し: ミュート切替
                                volume::toggle_mute();
                                info!("MARU Volume: mute toggled");
                            }
                            1 => {
                                // 長押し: 出力先切替（将来実装）
                                info!("MARU Volume: output switch (TODO)");
                            }
                            _ => {}
                        }
                        if let Err(e) = send_volume_state(&mut writer) {
                            error!("MARU write state failed: {}", e);
                            break;
                        }
                    }
                }

                DeviceMessage::Heartbeat { uptime_secs } => {
                    tracing::trace!("MARU Heartbeat: {}s", uptime_secs);
                }
            }
        }
    }
}

impl Default for MaruServer {
    fn default() -> Self {
        Self::new()
    }
}

/// サーバーハンドル
pub struct MaruHandle {
    running: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl MaruHandle {
    /// サーバーを停止
    pub fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for MaruHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

/// 現在の音量状態を StateUpdate として送信
fn send_volume_state(writer: &mut impl std::io::Write) -> std::io::Result<()> {
    let state = volume::get_volume_state();
    let msg = HostMessage::StateUpdate {
        mode_id: ModeId::Volume as u8,
        state_blob: state.to_payload(),
    };
    protocol::write_frame(writer, &msg)
}
