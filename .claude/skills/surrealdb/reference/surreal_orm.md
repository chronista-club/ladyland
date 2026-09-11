# Surreal ORM リファレンス

SurrealDB向けの強力なRust ORM/クエリビルダー。型安全なAPI、静的クエリチェック、完全自動マイグレーションを提供します。

## 概要

### 特徴

- **型安全**: コンパイル時のクエリ検証
- **マクロベース**: `Node`/`Edge`デリバイブマクロで簡潔な定義
- **クエリビルダー**: 流暢なAPIでSurrealQLを構築
- **トランザクション**: `transaction!`マクロで安全なトランザクション
- **マイグレーション**: CLIとEmbeddedの両方式に対応
- **複雑なクエリ**: `query_turbo!`マクロでネイティブライクな構文

## インストール

```toml
[dependencies]
surreal_orm = { git = "https://github.com/Oyelowo/surreal_orm" }
surrealdb = "2"
serde = { version = "1", features = ["derive"] }
tokio = { version = "1", features = ["full"] }
```

## 基本的な使い方

### Node（テーブル）定義

```rust
use surreal_orm::*;
use serde::{Deserialize, Serialize};

#[derive(Node, Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
#[orm(table = "user")]
pub struct User {
    pub id: SurrealSimpleId<Self>,
    pub name: String,
    pub email: String,
    pub age: u8,
}
```

### Edge（リレーション）定義

```rust
#[derive(Edge, Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
#[orm(table = "follows")]
pub struct Follows<In: Node, Out: Node> {
    pub id: SurrealSimpleId<Self>,
    #[serde(rename = "in")]
    pub in_: LinkOne<In>,
    pub out: LinkOne<Out>,
    pub created_at: chrono::DateTime<Utc>,
}

pub type UserFollowsUser = Follows<User, User>;
```

### 接続

```rust
use surrealdb::engine::local::Mem;
use surrealdb::Surreal;

#[tokio::main]
async fn main() {
    let db = Surreal::new::<Mem>(()).await.unwrap();
    db.use_ns("test").use_db("test").await.unwrap();
}
```

## CRUD操作

### SELECT

```rust
use surreal_orm::statements::{select, All};

let user::Schema { name, age, .. } = User::schema();
let user = User::table();

// 基本SELECT
let statement = select(All)
    .from(user)
    .where_(name.equal("John"))
    .order_by(age.desc())
    .limit(10);

// 実行
let users = statement.return_many::<User>(db.clone()).await?;
```

### INSERT

```rust
use surreal_orm::statements::insert;

let users = vec![
    User {
        id: User::create_simple_id(),
        name: "John".to_string(),
        email: "john@example.com".to_string(),
        age: 30,
    },
    User {
        id: User::create_simple_id(),
        name: "Jane".to_string(),
        email: "jane@example.com".to_string(),
        age: 25,
    },
];

insert(users).return_many(db.clone()).await?;
```

### CREATE

```rust
use surreal_orm::statements::create_only;

let user = create_only().content(User {
    id: User::create_id("john".into()),
    name: "John".to_string(),
    email: "john@example.com".to_string(),
    age: 30,
}).return_one::<User>(db.clone()).await?;
```

### UPDATE

```rust
use surreal_orm::statements::update;

let user::Schema { name, age, .. } = User::schema();
let user = User::table();

update(user)
    .content(User {
        name: "Updated Name".to_string(),
        ..Default::default()
    })
    .where_(cond(age.gt(25)))
    .return_many(db.clone())
    .await?;

// 部分更新（SET）
update::<User>("user:john")
    .set(age.increment_by(1))
    .return_one(db.clone())
    .await?;
```

### DELETE

```rust
use surreal_orm::statements::delete;

let user::Schema { name, age, .. } = User::schema();
let user = User::table();

delete(user)
    .where_(cond(name.eq("John")).and(age.lt(30)))
    .run(db.clone())
    .await?;
```

## クエリマクロ

### `query!` マクロ

SQLクエリを直接Rustで記述：

```rust
// 基本クエリ
let result = query!(db, "SELECT * FROM user").await;

// パラメータ付き
let username = "John";
let result = query!(db, "SELECT * FROM user WHERE name = $name AND age > $age", {
    name: username,
    age: 25
}).await;

// 複数クエリ
let results = query!(
    db,
    [
        "SELECT * FROM user WHERE score = $score",
        "CREATE user:john SET name = $name, skills = $skills"
    ],
    {
        score: 100,
        name: "John",
        skills: vec!["Rust", "TypeScript"]
    }
).await;
```

### `query_turbo!` マクロ

複雑なクエリをネイティブライクな構文で：

```rust
let query = query_turbo! {
    let users = select(All).from(User::table());

    for user in users {
        if user.age.gt(30) {
            update::<User>(user.id).set(user.status.eq("senior"));
        };
    };

    select(All).from(User::table());
};
```

## トランザクション

### `transaction!` マクロ

```rust
use surreal_orm::statements::{create_only, update};

let acc = Account::schema();

transaction! {
    BEGIN TRANSACTION;

    // 残高作成
    let balance = create_only().content(Balance {
        id: Balance::create_id("balance1".into()),
        amount: 300.00,
    });

    // アカウント作成
    create_only().content(Account {
        id: Account::create_id("one".into()),
        balance: 1000.00,
    });

    create_only().content(Account {
        id: Account::create_id("two".into()),
        balance: 500.00,
    });

    // 送金処理
    update::<Account>("account:one")
        .set(acc.balance.decrement_by(balance.with_path::<Balance>(E).amount));
    update::<Account>("account:two")
        .set(acc.balance.increment_by(300.00));

    COMMIT TRANSACTION;
}
.run(db.clone())
.await?;
```

### `block!` マクロ

```rust
let stats = create::<Stats>().set(object_partial!(Stats {
    averageScore: block! {
        let scores = select_value(score).from(User::table());
        let total = math::sum!(scores);
        let count = array::len!(scores);
        return math::ceil!((total / count) * 100);
    }
}));
```

## スキーマ定義

### Schemafullテーブル

```rust
#[derive(Node, Serialize, Deserialize, Debug, Clone, Default)]
#[serde(rename_all = "camelCase")]
#[orm(table = "user", schemafull)]
pub struct User {
    pub id: SurrealSimpleId<Self>,
    pub name: String,
    pub email: String,
    #[orm(type_ = "option<int>")]
    pub age: Option<i32>,
    pub created_at: chrono::DateTime<Utc>,
}
```

### インデックスとイベント

```rust
impl TableResources for User {
    fn indexes_definitions() -> Vec<Raw> {
        let user::Schema { email, name, .. } = Self::schema();

        let email_idx = define_index("email_idx")
            .on_table(Self::table())
            .fields(arr![email])
            .unique()
            .to_raw();

        let name_idx = define_index("name_idx")
            .on_table(Self::table())
            .fields(arr![name])
            .to_raw();

        vec![email_idx, name_idx]
    }

    fn events_definitions() -> Vec<Raw> {
        let user::Schema { name, .. } = Self::schema();

        let audit_event = define_event("user_created")
            .on_table(Self::table())
            .when(cond(name.is_not(NONE)))
            .then(create(AuditLog::table()).content(object!{
                action: "user_created",
                timestamp: time::now!()
            }))
            .to_raw();

        vec![audit_event]
    }
}
```

## マイグレーション

### リソース定義

```rust
use surreal_orm::migrator::Migrator;

#[derive(Debug, Clone)]
pub struct Resources;

impl DbResources for Resources {
    create_table_resources!(
        User,
        Post,
        UserFollowsUser,
    );

    fn analyzers(&self) -> Vec<Raw> { vec![] }
    fn functions(&self) -> Vec<Raw> { vec![] }
    fn params(&self) -> Vec<Raw> { vec![] }
    fn scopes(&self) -> Vec<Raw> { vec![] }
    fn tokens(&self) -> Vec<Raw> { vec![] }
    fn users(&self) -> Vec<Raw> { vec![] }
}

#[tokio::main]
async fn main() {
    Migrator::run(Resources).await;
}
```

### CLIコマンド

```bash
# 初期化（リバーシブル）
cargo run -- init --name "initial" -r

# マイグレーション生成
cargo run -- gen --name "add_posts_table"

# 適用
cargo run -- up           # 全て適用
cargo run -- up -n 5      # 5件適用
cargo run -- up -l        # 最新まで

# ロールバック
cargo run -- down         # 1つ戻す
cargo run -- down -n 3    # 3つ戻す
cargo run -- down --previous  # 前の状態へ

# 一覧
cargo run -- list

# リセット
cargo run -- reset

# 不要ファイル削除
cargo run -- prune
```

### Embeddedマイグレーション

```rust
use surreal_orm::migrator::{EmbeddedMigrator, Mode};

// コンパイル時にマイグレーションファイルを埋め込み
let migrator = EmbeddedMigrator::new(Resources)
    .with_mode(Mode::Strict);

migrator.up(&db).await?;
```

## ID型

### SurrealSimpleId

```rust
// 自動生成ID
pub id: SurrealSimpleId<Self>,

// 使用
let id = User::create_simple_id();
```

### SurrealId（カスタムID）

```rust
// 文字列ID
pub id: SurrealId<Self, String>,

// 使用
let id = User::create_id("custom_id".into());
```

### SurrealUuid

```rust
pub id: SurrealUuid<Self>,

// 使用
let id = User::create_uuid();
```

## リンク型

```rust
// 1対1
pub author: LinkOne<User>,

// 1対多
pub posts: LinkMany<Post>,

// 自己参照
pub parent: LinkSelf<Category>,
```

## フィールド操作

```rust
let user::Schema { balance, score, tags, .. } = User::schema();

// 数値操作
balance.increment_by(100.0)
balance.decrement_by(50.0)
score.eq(score.add(10))

// 配列操作
tags.push("new_tag")
tags.remove("old_tag")
array::len!(tags)

// 文字列操作
string::lowercase!(name)
string::concat!(first_name, " ", last_name)
```

## 公式リソース

- **GitHub**: https://github.com/Oyelowo/surreal_orm
- **Book**: https://oyelowo.github.io/surreal_orm
- **Discord**: https://discord.gg/Vrkq8KhGwN

## sdbk（TypeScript）との比較

| 機能 | surreal_orm (Rust) | sdbk (TypeScript) |
|------|-------------------|-------------------|
| 型安全 | ✅ コンパイル時 | ✅ コンパイル時 |
| スキーマ定義 | デリバイブマクロ | 関数ベース |
| クエリビルダー | ✅ 完全実装 | 計画中 |
| マイグレーション | ✅ CLI + Embedded | 計画中 |
| トランザクション | ✅ マクロサポート | 手動 |
| 成熟度 | 高い | 開発初期 |

## ユースケース

### いつsurreal_ormを使うべきか

- Rustプロジェクトでの本格的なSurrealDB利用
- 型安全なクエリ構築が必要
- 自動マイグレーションが必要
- 複雑なトランザクション処理
- グラフデータ（Edge）の操作

### 公式SDKのみで十分な場合

- シンプルなCRUD操作のみ
- 動的なクエリが主体
- 軽量な依存関係を維持したい
