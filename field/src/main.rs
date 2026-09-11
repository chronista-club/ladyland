//! fieldd — Ladyland System に常駐する **Field** サーバ（spec/08 / design/07）。
//!
//! **1 つの tokio タスクが 1 field のライフサイクルをまかなう**（mako 指定
//! 2026-08-14）。タスクが field state（エンティティ集合）を所有し、
//! 更新の受付と鼓動（FieldTick）の配信を行う。マルチ field はタスクを
//! 増やすだけ — v0 は "ladyland" の 1 field を常駐させる。
//!
//! クライアントは同格（design/07 §1）:
//! - ladyland (role=instruments) — スロットの姿を UpdateEntities で流す
//! - Vision Pro (role=visitor)  — Join して FieldTick を浴びる
//!
//! 通信は Unison Protocol（club-unison、QUIC）。schema は
//! `schemas/field.kdl` — enable_discovery で self-describing。

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, watch};
use tracing::{info, warn, Level};

use unison::network::channel::UnisonChannel;
use unison::network::{MessageType, ProtocolServer};

/// schema の SSOT はファイル（schemas/field.kdl）。ビルドに焼き込んで
/// discovery で配る — バイナリ 1 個で自己記述が完結する
const FIELD_KDL: &str = include_str!("../schemas/field.kdl");

/// バイナリの同一性（pkg version + ビルド時刻）。Ladyland が同梱版と
/// 突き合わせ、不一致なら Shutdown → 新版 spawn で入れ替える（自動アプデ）。
/// 順序比較はしない — **完全一致か否か**だけ（シンプルで十分）
const FIELDD_VERSION: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    "+",
    env!("FIELDD_BUILD_TS")
);

/// 待ち受けの既定。**LAN に開く**（Vision Pro 実機は別デバイスから届く
/// 必要がある。v0 はスタジオ LAN 前提・認証なし — 外に出すときは auth を
/// 足すこと）。⚠️ ポート台帳（creo-port-ssot）に bikeboy の block は
/// 未取得 — 正式な番号は台帳で取ってから。それまでは unison 慣例 7878 の
/// 隣に仮住まい（FIELDD_ADDR で上書き可）
const DEFAULT_ADDR: &str = "[::]:7879";

/// field のエンティティ（v0 = ladyland のスロットの写し。
/// 形は schemas/field.kdl の doc コメントが正）
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Entity {
    /// トラック番号（1-64）
    id: u32,
    name: String,
    /// トラックカラー "#RRGGBB"（null = 未設定。ROTO の palette index は
    /// ladyland 内部の語 — wire は見た目に必要な形で運ぶ）
    color: Option<String>,
    selected: bool,
    /// 出音 peak 0.0-1.0（ladyland の per-slot tap ~23Hz）
    level: f32,
}

/// field タスクへの口（handler 側が持つハンドル）
#[derive(Clone)]
struct FieldHandle {
    update: mpsc::Sender<Vec<Entity>>,
    /// 鼓動の購読口（payload は FieldTick の中身）
    tick: broadcast::Sender<Value>,
    /// 最新スナップショット（Join 応答用 — 次の tick を待たせない）
    snapshot: watch::Receiver<Value>,
}

/// **1 field = 1 タスク**。生成 → 常駐（更新受付 + 鼓動）→ 全ハンドルが
/// 落ちたら終了、というライフサイクルをこのタスクが所有する
fn spawn_field(name: &'static str) -> FieldHandle {
    let (update_tx, mut update_rx) = mpsc::channel::<Vec<Entity>>(64);
    let (tick_tx, _) = broadcast::channel::<Value>(16);
    let (snapshot_tx, snapshot_rx) = watch::channel(json!({ "entities": [] }));

    let tick_out = tick_tx.clone();
    tokio::spawn(async move {
        let mut entities: Vec<Entity> = Vec::new();
        let mut dirty = false;
        // 鼓動 30Hz — ladyland の peak（~23Hz）を取りこぼさない最小の律動。
        // 変化がない間は 1 秒に 1 回のハートビートへ落とす（常駐 = 心拍）
        let mut ticker = tokio::time::interval(Duration::from_millis(33));
        let mut last_sent = tokio::time::Instant::now();
        info!("field \"{name}\": 常駐開始");
        loop {
            tokio::select! {
                update = update_rx.recv() => match update {
                    Some(next) => {
                        entities = next;
                        dirty = true;
                    }
                    // 全 sender が消えた = サーバごと畳まれている
                    None => break,
                },
                _ = ticker.tick() => {
                    let heartbeat = last_sent.elapsed() >= Duration::from_secs(1);
                    if dirty || heartbeat {
                        let payload = json!({ "entities": entities });
                        let _ = snapshot_tx.send(payload.clone());
                        // 購読者ゼロは Err — 場は無人でも生きているので無視
                        let _ = tick_out.send(payload);
                        dirty = false;
                        last_sent = tokio::time::Instant::now();
                    }
                }
            }
        }
        info!("field \"{name}\": 終了");
    });

    FieldHandle { update: update_tx, tick: tick_tx, snapshot: snapshot_rx }
}

/// presence チャネル — 接続 1 本ぶんの応対。
/// Join で購読（send_event 側は別タスク — recv と並行に鼓動を流す）、
/// UpdateEntities で field へ流し込む
async fn serve_presence(
    field: FieldHandle,
    channel: Arc<UnisonChannel>,
) -> std::result::Result<(), unison::network::NetworkError> {
    let mut ticker: Option<tokio::task::JoinHandle<()>> = None;
    // 🧪 供給の生存統計（実機切り分け 2026-08-15「弾いても何もない」—
    // Ladyland → fieldd の半分が生きているかを 10 秒ごとに出す）
    let mut updates: u64 = 0;
    let mut decode_failures: u64 = 0;
    let mut last_stat = tokio::time::Instant::now();
    loop {
        match channel.recv().await {
            Ok(msg) if msg.msg_type == MessageType::Request => {
                let payload = msg.payload_as_value().unwrap_or_default();
                match msg.method.as_str() {
                    "Join" => {
                        let role = payload
                            .get("role")
                            .and_then(|v| v.as_str())
                            .unwrap_or("visitor")
                            .to_string();
                        info!("join: role={role} (fieldd {FIELDD_VERSION})");
                        // 鼓動の購読（多重 Join は張り直さない）
                        if ticker.is_none() {
                            let mut rx = field.tick.subscribe();
                            let sender = channel.clone();
                            ticker = Some(tokio::spawn(async move {
                                loop {
                                    match rx.recv().await {
                                        Ok(tick) => {
                                            if sender.send_event("FieldTick", &tick).await.is_err() {
                                                break; // 接続が閉じた
                                            }
                                        }
                                        // 溢れたら追い付く（最新だけ欲しい値ストリーム）
                                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                                        Err(broadcast::error::RecvError::Closed) => break,
                                    }
                                }
                            }));
                        }
                        // snapshot + 自分の版（Ladyland が同梱版と突き合わせる）
                        let mut snapshot = field.snapshot.borrow().clone();
                        if let Some(object) = snapshot.as_object_mut() {
                            object.insert("server_version".into(), json!(FIELDD_VERSION));
                        }
                        channel.send_response(msg.id, &msg.method, &snapshot).await?;
                    }
                    // 入れ替えのための退場（Ladyland の自動アプデ経路。v0 は
                    // LAN 前提で認証なし — 外に出すときは auth 必須）
                    "Shutdown" => {
                        info!("shutdown 要求 — 入れ替えのため退く");
                        channel.send_response(msg.id, &msg.method, &json!({})).await?;
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        std::process::exit(0);
                    }
                    "UpdateEntities" => {
                        // ⚠️ デコード失敗を握りつぶさない — 空受理は「供給が
                        // 生きているのに場が空」という一番分かりにくい故障になる
                        // 供給は 10Hz — warn を毎回出すと洪水になるので、
                        // 初回だけ形を出し、以降は 10 秒統計の件数に畳む
                        // （実例 2026-08-15: 旧 Ladyland が color を整数で送り、
                        // 1 スロットの型ズレで 64 体全部が空に落ちていた）
                        let entities: Vec<Entity> = match payload.get("entities").cloned() {
                            Some(value) => match serde_json::from_value(value) {
                                Ok(entities) => entities,
                                Err(err) => {
                                    if decode_failures == 0 {
                                        warn!("UpdateEntities デコード失敗（初回のみ表示）: {err}");
                                    }
                                    decode_failures += 1;
                                    Vec::new()
                                }
                            },
                            None => {
                                decode_failures += 1;
                                Vec::new()
                            }
                        };
                        updates += 1;
                        if last_stat.elapsed() >= Duration::from_secs(10) {
                            let selected = entities.iter().find(|e| e.selected);
                            info!(
                                "updates: {updates} 件（失敗 {decode_failures}）/ {} 体 / selected = {} (level {:.3})",
                                entities.len(),
                                selected.map(|e| e.name.as_str()).unwrap_or("-"),
                                selected.map(|e| e.level).unwrap_or(0.0)
                            );
                            last_stat = tokio::time::Instant::now();
                        }
                        if field.update.send(entities).await.is_err() {
                            warn!("field task が居ない — 更新を捨てた");
                        }
                        channel.send_response(msg.id, &msg.method, &json!({})).await?;
                    }
                    other => {
                        warn!("未知の request: {other}");
                    }
                }
            }
            Ok(_) => continue,
            Err(e) if e.is_normal_close() => break,
            Err(e) => {
                if let Some(t) = ticker.take() {
                    t.abort();
                }
                return Err(e);
            }
        }
    }
    if let Some(t) = ticker.take() {
        t.abort();
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    // --version: Ladyland が同梱バイナリの版を知るための口（spawn 前に 1 回叩く）
    if std::env::args().any(|a| a == "--version") {
        println!("fieldd {FIELDD_VERSION}");
        return Ok(());
    }
    tracing_subscriber::fmt()
        .with_max_level(Level::INFO)
        .with_target(false)
        .init();

    // v0 は field 1 つ。増やすときは spawn_field を呼び足すだけ（1 task = 1 field）
    let field = spawn_field("ladyland");

    let server = ProtocolServer::with_identity("field", "0.1.0", "ladyland.field");
    server.enable_discovery(FIELD_KDL).await?;

    let handle = field.clone();
    server
        .register_channel("presence", move |_ctx, stream| {
            let field = handle.clone();
            async move {
                let channel = Arc::new(UnisonChannel::new(stream));
                serve_presence(field, channel).await
            }
        })
        .await;

    let addr = std::env::var("FIELDD_ADDR").unwrap_or_else(|_| DEFAULT_ADDR.to_string());
    info!("fieldd: field \"ladyland\" 常駐、{addr} で待ち受け");
    server.listen(&addr).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1 field = 1 タスクの心臓部 — 更新が鼓動（tick と snapshot）に出る
    #[tokio::test]
    async fn 更新が鼓動に出る() {
        let field = spawn_field("test");
        let mut rx = field.tick.subscribe();
        field
            .update
            .send(vec![Entity {
                id: 17,
                name: "Chicago".into(),
                color: Some("#E5343E".into()),
                selected: true,
                level: 0.5,
            }])
            .await
            .unwrap();
        // 33ms tick を跨いで受く
        let tick = tokio::time::timeout(Duration::from_millis(500), rx.recv())
            .await
            .expect("tick が来ない")
            .unwrap();
        let entities = tick.get("entities").unwrap().as_array().unwrap();
        assert_eq!(entities.len(), 1);
        assert_eq!(entities[0]["id"], 17);
        assert_eq!(entities[0]["name"], "Chicago");
        assert_eq!(entities[0]["selected"], true);
        // snapshot も同じ姿（Join 応答が場を即座に映せる）
        let snapshot = field.snapshot.borrow().clone();
        assert_eq!(snapshot["entities"][0]["id"], 17);
    }

    /// 変化がなくても 1 秒に 1 回の心拍がある（常駐の生存証明）
    #[tokio::test]
    async fn 無変化でも心拍がある() {
        let field = spawn_field("heartbeat");
        let mut rx = field.tick.subscribe();
        let first = tokio::time::timeout(Duration::from_millis(1500), rx.recv()).await;
        assert!(first.is_ok(), "1 秒ハートビートが来ない");
    }
}
