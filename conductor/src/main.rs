mod config;
mod monitor;
mod fleetflow;
mod health;

use std::path::PathBuf;
use tracing::{info, error};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // ログ初期化
    tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer())
        .with(tracing_subscriber::EnvFilter::from_default_env()
            .add_directive("conductor=info".parse()?))
        .init();

    info!("conductor 起動");

    // 設定読み込み
    let config_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("conductor.kdl"));

    let config = match config::load_config(&config_path) {
        Ok(c) => c,
        Err(e) => {
            error!("設定読み込みエラー: {}", e);
            // デフォルト設定で起動
            config::Config::default()
        }
    };

    info!("監視開始: stage={}, interval={}s", config.stage, config.interval_secs);

    // 監視ループ開始
    monitor::run_monitor(config).await
}
