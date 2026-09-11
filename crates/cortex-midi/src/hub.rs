//! MidiHub — リグ全機材の同時接続とデバイス識別
//!
//! design/05 §7 S1。既存の `MidiHandler`（1台前提）を N 台に拡張し、
//! イベントに「どの機材から来たか」を付与する。
//!
//! ## 設計原則（doc 05 §5）
//! - **fail-open**: 見つからない機材はスキップして起動する。1台も無くても失敗しない
//! - **ホワイトリスト**: 既知のポートだけ開く。未知の仮想ポートを勝手に掴まない
//!   （S4 で KDL 設定に外出し予定。それまでは `port_policy` が SSOT）
//! - **専用ハンドラとの棲み分け**: X-Touch は `xtouch.rs` が掴むため hub は開かない
//!
//! ## 開かないポートの根拠
//! - `L6max for L6 Editor Port` — 公式マニュアルが「使用しないでください」と明記
//!   （docs/l6max/README.md §2。先に掴むと L6 Editor が接続不能になる）
//! - `Keystage DAW IN` — DAW 制御専用（ch16 の CC が流れる）。楽器経路では不要
//!   （docs/keystage/README.md §1）

use crate::handler::{MidiEvent, MidiHandler};

/// リグの機材種別（design/05 §2 の機材グラフ）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceKind {
    /// Keystage KBD/CTRL — メイン楽器（鍵盤・ポリAT・ノブ）
    Keystage,
    /// LPD8 mk2 — パッド・切替系
    Lpd8,
    /// ROTO-CONTROL — パラメータ操作（歩く層）
    Roto,
    /// L6max Mixer Control Port — 卓の状態（CC 双方向）
    L6maxMixer,
    /// L6max MIDI I/O Port — 物理 MIDI IN/OUT 端子の素通し（外部機器用）
    L6maxMidiIo,
}

impl DeviceKind {
    /// 表示名
    pub fn label(&self) -> &'static str {
        match self {
            DeviceKind::Keystage => "Keystage",
            DeviceKind::Lpd8 => "LPD8 mk2",
            DeviceKind::Roto => "ROTO-CONTROL",
            DeviceKind::L6maxMixer => "L6max (Mixer Control)",
            DeviceKind::L6maxMidiIo => "L6max (MIDI I/O)",
        }
    }
}

/// ポート名 → 接続方針。`None` = 開かない。
///
/// rigcheck 実測のポート名（2026-07-26）に基づく:
/// "Keystage KBD/CTRL" / "Keystage DAW IN" / "LPD8 mk2" / "Roto-Control" /
/// "L6max MIDI I/O Port" / "L6max Mixer Control Port" / "L6max for L6 Editor Port" /
/// "X-Touch INT" / "X-Touch EXT"
pub fn port_policy(port_name: &str) -> Option<DeviceKind> {
    let n = port_name.to_lowercase();

    // --- 開かないポート（理由はモジュール docコメント） ---
    if n.contains("l6 editor") {
        return None; // 公式禁止
    }
    if n.contains("keystage daw") {
        return None; // DAW 制御専用
    }
    if n.contains("x-touch") {
        return None; // xtouch.rs の専用ハンドラが掴む
    }

    // --- 接続対象 ---
    if n.contains("keystage") {
        return Some(DeviceKind::Keystage); // KBD/CTRL 側
    }
    if n.contains("lpd8") {
        return Some(DeviceKind::Lpd8);
    }
    if n.contains("roto") {
        return Some(DeviceKind::Roto);
    }
    if n.contains("mixer control") {
        return Some(DeviceKind::L6maxMixer);
    }
    if n.contains("l6max midi i/o") {
        return Some(DeviceKind::L6maxMidiIo);
    }

    None // 未知のポートは開かない（ホワイトリスト方針）
}

/// デバイス識別つき MIDI イベント
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub device: DeviceKind,
    pub event: MidiEvent,
}

/// 1 台ぶんの接続
struct HubConnection {
    device: DeviceKind,
    port_name: String,
    handler: MidiHandler,
}

/// リグ全体の MIDI 入力ハブ
pub struct MidiHub {
    connections: Vec<HubConnection>,
}

impl MidiHub {
    /// 既知のリグ機材をすべて接続する。
    ///
    /// fail-open: 個々の接続失敗は警告してスキップ。機材ゼロでも Ok を返す。
    pub fn connect_rig() -> Self {
        let mut hub = Self {
            connections: Vec::new(),
        };
        hub.reconnect_missing();
        hub
    }

    /// 未接続の既知機材を再スキャンして接続する（ホットプラグ対応の芽）。
    ///
    /// 接続できた台数を返す。既に接続済みの機材はそのまま。
    pub fn reconnect_missing(&mut self) -> usize {
        let ports = match MidiHandler::list_ports() {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!("MIDI port enumeration failed: {}", e);
                return 0;
            }
        };

        let mut added = 0;
        for port_name in ports {
            let Some(kind) = port_policy(&port_name) else {
                continue;
            };
            // 同種は 1 接続まで（Keystage の複数ポート等で二重に掴まない）
            if self.connections.iter().any(|c| c.device == kind) {
                continue;
            }

            let mut handler = match MidiHandler::new() {
                Ok(h) => h,
                Err(e) => {
                    tracing::warn!("{}: handler creation failed: {}", kind.label(), e);
                    continue;
                }
            };
            match handler.connect(&port_name) {
                Ok(()) => {
                    tracing::info!("MidiHub: {} connected ({})", kind.label(), port_name);
                    self.connections.push(HubConnection {
                        device: kind,
                        port_name,
                        handler,
                    });
                    added += 1;
                }
                Err(e) => {
                    // fail-open: この機材だけスキップ
                    tracing::warn!("{}: connect failed: {}", kind.label(), e);
                }
            }
        }
        added
    }

    /// 全接続からイベントを回収する（デバイス識別つき）
    pub fn poll_events(&self) -> Vec<HubEvent> {
        let mut events = Vec::new();
        for conn in &self.connections {
            for event in conn.handler.poll_events() {
                events.push(HubEvent {
                    device: conn.device,
                    event,
                });
            }
        }
        events
    }

    /// 接続中の機材一覧（種別, ポート名）
    pub fn connected_devices(&self) -> Vec<(DeviceKind, &str)> {
        self.connections
            .iter()
            .map(|c| (c.device, c.port_name.as_str()))
            .collect()
    }

    /// 指定種別が接続済みか
    pub fn is_connected(&self, kind: DeviceKind) -> bool {
        self.connections.iter().any(|c| c.device == kind)
    }

    /// 接続台数
    pub fn len(&self) -> usize {
        self.connections.len()
    }

    /// 接続ゼロか
    pub fn is_empty(&self) -> bool {
        self.connections.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// rigcheck 実測（2026-07-26）の実ポート名で方針を固定する。
    /// 機材リネームや実装変更でこのテストが割れたら docs/ の README と突き合わせること。
    #[test]
    fn policy_connects_rig_instruments() {
        assert_eq!(
            port_policy("Keystage KBD/CTRL"),
            Some(DeviceKind::Keystage)
        );
        assert_eq!(port_policy("LPD8 mk2"), Some(DeviceKind::Lpd8));
        assert_eq!(port_policy("Roto-Control"), Some(DeviceKind::Roto));
        assert_eq!(
            port_policy("L6max Mixer Control Port"),
            Some(DeviceKind::L6maxMixer)
        );
        assert_eq!(
            port_policy("L6max MIDI I/O Port"),
            Some(DeviceKind::L6maxMidiIo)
        );
    }

    #[test]
    fn policy_rejects_forbidden_and_special_ports() {
        // 公式に使用禁止（L6 Editor が繋がらなくなる）
        assert_eq!(port_policy("L6max for L6 Editor Port"), None);
        // DAW 制御専用（ch16 CC ノイズ）
        assert_eq!(port_policy("Keystage DAW IN"), None);
        // X-Touch は専用ハンドラの領分
        assert_eq!(port_policy("X-Touch INT"), None);
        assert_eq!(port_policy("X-Touch EXT"), None);
    }

    #[test]
    fn policy_rejects_unknown_ports() {
        // ホワイトリスト方針: 未知の仮想ポートを勝手に掴まない
        assert_eq!(port_policy("IAC Driver Bus 1"), None);
        assert_eq!(port_policy("Some Random Synth"), None);
        assert_eq!(port_policy(""), None);
    }

    #[test]
    fn policy_is_case_insensitive() {
        assert_eq!(port_policy("KEYSTAGE KBD/CTRL"), Some(DeviceKind::Keystage));
        assert_eq!(port_policy("lpd8 MK2"), Some(DeviceKind::Lpd8));
    }
}
