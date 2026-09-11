# FleetFlow KDL連携

FleetFlowでのKDL設定ファイル記述ガイドです。

## ファイル配置

```
project/
├── flow.kdl              # メイン設定
├── flow.local.kdl        # ローカル設定（.gitignore推奨）
└── .fleetflow/
    └── flow.kdl          # 代替配置
```

### 検索優先順位

1. 環境変数 `FLOW_CONFIG_PATH`
2. `flow.local.kdl`
3. `.flow.local.kdl`
4. `flow.kdl`
5. `.flow.kdl`
6. `.fleetflow/flow.kdl`

## 基本構造

```kdl
project "project-name"

stage "stage-name" {
    service "service-name"
}

service "service-name" {
    image "image-name"
    version "tag"
    ports { ... }
    environment { ... }  // 注意: env ではなく environment
    volumes { ... }
}
```

## プロジェクト宣言

```kdl
project "creo-memories"
```

- **必須**: ファイルの最初に宣言
- **用途**: コンテナ命名規則 `{project}-{stage}-{service}`

## ステージ定義

```kdl
stage "local" {
    service "db"
    service "app"
}

stage "prod" {
    service "db"
    service "app"
    service "nginx"
}
```

- 環境ごとに異なるサービス構成が可能
- 同じサービス名でも定義は共有

## サービス定義

### イメージ指定

```kdl
service "db" {
    image "postgres"
    version "16-alpine"
}
```

| image | version | 結果 |
|-------|---------|------|
| あり | あり | `image:version` |
| あり | なし | `image:latest` |
| なし | あり | `service-name:version` |
| なし | なし | `service-name:latest` |

### ポート設定

```kdl
ports {
    port host=8080 container=3000
    port host=5432 container=5432
}
```

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `host` | ✅ | ホスト側ポート |
| `container` | ✅ | コンテナ内ポート |
| `protocol` | - | `tcp`(デフォルト) / `udp` |

### 環境変数

```kdl
environment {
    DATABASE_URL "postgres://localhost:5432/mydb"
    DEBUG "true"
    NODE_ENV "development"
}
```

**重要**:
- ブロック名は `environment`（`env`ではない）
- 値は必ず引用符で囲む

### ボリューム

```kdl
volumes {
    volume host="./data" container="/var/lib/data"
    volume host="/config" container="/etc/config" read_only=#true
}
```

**注意**: KDL v2ではブール値は `#true`/`#false`（`true`ではない）

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| `host` | ✅ | ホスト側パス |
| `container` | ✅ | コンテナ内パス |
| `read_only` | - | 読み取り専用 |

### コマンド

```kdl
command "postgres -c max_connections=200"
```

### ビルド設定

```kdl
build {
    dockerfile "services/api/Dockerfile"
    context "."
    args {
        RUST_VERSION "1.75"
    }
    target "production"
}
```

## 完全な例

```kdl
project "my-app"

stage "local" {
    service "db"
    service "redis"
    service "api"
}

stage "prod" {
    service "db"
    service "redis"
    service "api"
    service "nginx"
}

service "db" {
    image "postgres"
    version "16-alpine"
    ports {
        port host=5432 container=5432
    }
    environment {
        POSTGRES_DB "myapp"
        POSTGRES_USER "myapp"
        POSTGRES_PASSWORD "secret"
    }
    volumes {
        volume host="./data/postgres" container="/var/lib/postgresql/data"
    }
}

service "redis" {
    image "redis"
    version "7-alpine"
    ports {
        port host=6379 container=6379
    }
}

service "api" {
    build {
        dockerfile "Dockerfile"
        context "."
    }
    ports {
        port host=3000 container=3000
    }
    environment {
        DATABASE_URL "postgres://myapp:secret@db:5432/myapp"
        REDIS_URL "redis://redis:6379"
    }
}

service "nginx" {
    image "nginx"
    version "alpine"
    ports {
        port host=80 container=80
        port host=443 container=443
    }
    volumes {
        volume host="./nginx.conf" container="/etc/nginx/nginx.conf" read_only=#true
    }
}
```

## よくあるエラー

### 1. 環境変数ブロック名の間違い

```kdl
// NG: env は認識されない
env {
    DATABASE_URL "postgres://localhost"
}

// OK: environment を使用
environment {
    DATABASE_URL "postgres://localhost"
}
```

### 2. 値の引用符忘れ

```kdl
// NG
environment {
    URL http://example.com
}

// OK
environment {
    URL "http://example.com"
}
```

### 3. ブール値の書き方

```kdl
// NG: KDL v2では true は識別子
read_only=true

// OK: #接頭辞が必要
read_only=#true
```

### 4. プロパティ形式の間違い

```kdl
// NG: ポートの形式
port 8080 3000

// OK: 名前付き引数
port host=8080 container=3000
```

### 5. ブロック内のコメント位置

```kdl
// NG: 一部のパーサーで問題
environment {
    KEY "value" // comment
}

// OK: 別行にコメント
environment {
    // comment
    KEY "value"
}
```

## 既知の制限事項

### コンテナ間ネットワーク

FleetFlow v0.2.xでは、コンテナ間のDNS解決が自動設定されません。
サービス名（例: `surrealdb`, `qdrant`）での接続が必要な場合、
手動でDockerネットワークを作成・接続する必要があります。

```bash
# ワークアラウンド
docker network create {project}-{stage}
docker network connect --alias {service} {project}-{stage} {container-name}
```

## 検証

```bash
fleetflow validate
```

エラーが出たら:
1. `environment`（`env`ではない）を確認
2. `#true`/`#false`の形式を確認
3. 引用符を確認
4. `{}`の対応を確認
