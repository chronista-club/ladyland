use std::process::Command;
use thiserror::Error;
use tracing::{debug, warn};

#[derive(Error, Debug)]
pub enum FleetFlowError {
    #[error("コマンド実行エラー: {0}")]
    Command(#[from] std::io::Error),

    #[error("fleetflow エラー: {0}")]
    FleetFlow(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServiceStatus {
    Up,
    Down,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct ServiceState {
    pub name: String,
    pub status: ServiceStatus,
}

/// fleetflow ps を実行してサービス状態を取得
pub fn get_service_status(stage: &str) -> Result<Vec<ServiceState>, FleetFlowError> {
    let output = Command::new("fleetflow")
        .args(["ps", "-s", stage])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(FleetFlowError::FleetFlow(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_ps_output(&stdout)
}

/// fleetflow ps の出力をパース
fn parse_ps_output(output: &str) -> Result<Vec<ServiceState>, FleetFlowError> {
    let mut services = Vec::new();

    for line in output.lines() {
        // ヘッダーや区切り線をスキップ
        if line.starts_with("NAME") || line.starts_with("─") || line.trim().is_empty() {
            continue;
        }

        // ANSIエスケープシーケンスを含む行もスキップ
        if line.contains("[2m") || line.contains("INFO") {
            continue;
        }

        // 行をパース: "NAME STATUS IMAGE PORTS"
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 {
            let name = parts[0].to_string();
            let status_str = parts[1].to_lowercase();

            let status = if status_str.contains("up") {
                ServiceStatus::Up
            } else if status_str.contains("down") || status_str.contains("exited") {
                ServiceStatus::Down
            } else {
                ServiceStatus::Unknown
            };

            debug!("サービス検出: {} = {:?}", name, status);
            services.push(ServiceState { name, status });
        }
    }

    Ok(services)
}

/// サービスを起動
pub fn start_service(stage: &str) -> Result<(), FleetFlowError> {
    let output = Command::new("fleetflow")
        .args(["up", "-s", stage])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!("fleetflow up 失敗: {}", stderr);
        return Err(FleetFlowError::FleetFlow(stderr.to_string()));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_ps_output() {
        let output = r#"
NAME                 STATUS          IMAGE                PORTS
─────────────────────────────────────────────────────────────────────────────────────────────────────────
bikeboy-local-surrealdb Up About a minute surrealdb/surrealdb:v2 8000:8000
"#;
        let services = parse_ps_output(output).unwrap();
        assert_eq!(services.len(), 1);
        assert_eq!(services[0].name, "bikeboy-local-surrealdb");
        assert_eq!(services[0].status, ServiceStatus::Up);
    }
}
