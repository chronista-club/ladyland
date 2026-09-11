use std::path::Path;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("ファイル読み込みエラー: {0}")]
    Io(#[from] std::io::Error),

    #[error("KDLパースエラー: {0}")]
    Parse(#[from] kdl::KdlError),

    #[error("設定エラー: {0}")]
    Invalid(String),
}

#[derive(Debug, Clone)]
pub struct ServiceConfig {
    pub name: String,
    pub health_check: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub interval_secs: u64,
    pub stage: String,
    pub services: Vec<ServiceConfig>,
    pub max_restarts_per_hour: u32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            interval_secs: 30,
            stage: "local".to_string(),
            services: vec![],
            max_restarts_per_hour: 5,
        }
    }
}

pub fn load_config(path: &Path) -> Result<Config, ConfigError> {
    let content = std::fs::read_to_string(path)?;
    let doc = content.parse::<kdl::KdlDocument>()?;

    let mut config = Config::default();

    // conductor ノードを探す
    for node in doc.nodes() {
        if node.name().value() == "conductor" {
            // interval
            if let Some(interval) = node.get("interval") {
                if let Some(v) = interval.value().as_i64() {
                    config.interval_secs = v as u64;
                }
            }

            // stage
            if let Some(stage) = node.get("stage") {
                if let Some(v) = stage.value().as_string() {
                    config.stage = v.to_string();
                }
            }

            // max-restarts
            if let Some(max) = node.get("max-restarts") {
                if let Some(v) = max.value().as_i64() {
                    config.max_restarts_per_hour = v as u32;
                }
            }

            // 子ノードからサービス設定を取得
            if let Some(children) = node.children() {
                for child in children.nodes() {
                    if child.name().value() == "service" {
                        if let Some(name) = child.entries().first() {
                            if let Some(name_str) = name.value().as_string() {
                                let health_check = child.get("health-check")
                                    .and_then(|v| v.value().as_string())
                                    .map(|s| s.to_string());

                                config.services.push(ServiceConfig {
                                    name: name_str.to_string(),
                                    health_check,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_parse_config() {
        let mut file = NamedTempFile::new().unwrap();
        writeln!(file, r#"
conductor interval=30 stage="local" max-restarts=5 {{
    service "surrealdb" health-check="http://localhost:8000/health"
}}
"#).unwrap();

        let config = load_config(file.path()).unwrap();
        assert_eq!(config.interval_secs, 30);
        assert_eq!(config.stage, "local");
        assert_eq!(config.services.len(), 1);
        assert_eq!(config.services[0].name, "surrealdb");
    }
}
