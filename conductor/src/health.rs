use thiserror::Error;
use tracing::debug;

#[derive(Error, Debug)]
pub enum HealthError {
    #[error("HTTPエラー: {0}")]
    Http(#[from] reqwest::Error),

    #[error("ヘルスチェック失敗: status={0}")]
    Unhealthy(u16),
}

/// URLに対してヘルスチェックを実行
pub async fn check_health(url: &str) -> Result<bool, HealthError> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()?;

    debug!("ヘルスチェック: {}", url);

    let response = client.get(url).send().await?;
    let status = response.status();

    if status.is_success() {
        debug!("ヘルスチェック成功: {} -> {}", url, status);
        Ok(true)
    } else {
        debug!("ヘルスチェック失敗: {} -> {}", url, status);
        Err(HealthError::Unhealthy(status.as_u16()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_health_check_invalid_url() {
        let result = check_health("http://localhost:99999/health").await;
        assert!(result.is_err());
    }
}
