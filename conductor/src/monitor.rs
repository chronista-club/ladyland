use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio::time::sleep;
use tracing::{info, warn, error};

use crate::config::Config;
use crate::fleetflow::{self, ServiceStatus};
use crate::health;

#[derive(Debug)]
struct ServiceTracker {
    restart_count: u32,
    last_restart: Option<Instant>,
    consecutive_failures: u32,
}

impl Default for ServiceTracker {
    fn default() -> Self {
        Self {
            restart_count: 0,
            last_restart: None,
            consecutive_failures: 0,
        }
    }
}

/// バックオフ時間を計算
fn calculate_backoff(failures: u32) -> Duration {
    let base_secs = 5u64;
    let max_secs = 300u64; // 5分
    let delay = base_secs * 2u64.pow(failures.min(6));
    Duration::from_secs(delay.min(max_secs))
}

/// 監視ループを実行
pub async fn run_monitor(config: Config) -> Result<(), Box<dyn std::error::Error>> {
    let mut trackers: HashMap<String, ServiceTracker> = HashMap::new();
    let interval = Duration::from_secs(config.interval_secs);

    loop {
        // FleetFlowからサービス状態を取得
        match fleetflow::get_service_status(&config.stage) {
            Ok(services) => {
                for service in services {
                    let tracker = trackers
                        .entry(service.name.clone())
                        .or_insert_with(ServiceTracker::default);

                    match service.status {
                        ServiceStatus::Up => {
                            // 正常稼働中
                            if tracker.consecutive_failures > 0 {
                                info!("{} 復旧確認", service.name);
                                tracker.consecutive_failures = 0;
                            }
                        }
                        ServiceStatus::Down => {
                            warn!("{} ダウン検出", service.name);
                            tracker.consecutive_failures += 1;

                            // バックオフチェック
                            let should_restart = match tracker.last_restart {
                                Some(last) => {
                                    let backoff = calculate_backoff(tracker.consecutive_failures);
                                    last.elapsed() >= backoff
                                }
                                None => true,
                            };

                            // 時間あたりの再起動制限チェック
                            let within_limit = tracker.restart_count < config.max_restarts_per_hour;

                            if should_restart && within_limit {
                                info!("{} 再起動試行 ({}回目)", service.name, tracker.restart_count + 1);

                                match fleetflow::start_service(&config.stage) {
                                    Ok(_) => {
                                        info!("{} 再起動コマンド成功", service.name);
                                        tracker.restart_count += 1;
                                        tracker.last_restart = Some(Instant::now());
                                    }
                                    Err(e) => {
                                        error!("{} 再起動失敗: {}", service.name, e);
                                    }
                                }
                            } else if !within_limit {
                                error!("{} 再起動制限に到達（{}回/時間）", service.name, config.max_restarts_per_hour);
                            }
                        }
                        ServiceStatus::Unknown => {
                            warn!("{} 状態不明", service.name);
                        }
                    }
                }

                // 設定されたサービスのヘルスチェック
                for svc_config in &config.services {
                    if let Some(url) = &svc_config.health_check {
                        match health::check_health(url).await {
                            Ok(true) => {
                                // 正常
                            }
                            Ok(false) | Err(_) => {
                                warn!("{} ヘルスチェック失敗: {}", svc_config.name, url);
                            }
                        }
                    }
                }
            }
            Err(e) => {
                error!("FleetFlow状態取得エラー: {}", e);
            }
        }

        // 1時間経過したら再起動カウントをリセット
        for tracker in trackers.values_mut() {
            if let Some(last) = tracker.last_restart {
                if last.elapsed() >= Duration::from_secs(3600) {
                    tracker.restart_count = 0;
                }
            }
        }

        sleep(interval).await;
    }
}
