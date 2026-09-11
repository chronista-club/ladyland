# SurrealDBKit (sdbk) リファレンス

SurrealDB向けの型安全なTypeScriptツールキット。コンパイル時の型検証、クエリビルダー、開発ツールを提供します。

> ⚠️ **Early Development**: 積極的に開発中のプロジェクト。APIは変更される可能性があります。

## 概要

### 特徴

- **型安全**: TypeScriptによるコンパイル時の型検証
- **開発者体験**: 直感的なAPIと便利なツール
- **パフォーマンス**: 型操作のランタイムオーバーヘッドなし
- **モジュラー**: 必要な機能のみを使用可能

## インストール

```bash
# Bunを推奨
bun add @sdbk/core

# npm/yarn
npm install @sdbk/core
yarn add @sdbk/core
```

### 要件

- **TypeScript**: >= 5.0.0
- **Node.js**: >= 18.0.0
- **Bun**: >= 1.3.3（推奨）

## パッケージ構成

### `@sdbk/core`（利用可能）

基盤となる型定義とユーティリティを提供：

- エンティティとフィールドの型定義
- 式ビルダーと識別子
- スキーマ型システム
- ランタイム型ガード
- 共有ユーティリティ

### 計画中のパッケージ

```
@sdbk/client  - 型安全なSurrealDBクライアントラッパー
@sdbk/query   - 型推論付きクエリビルダー
@sdbk/migrate - スキーママイグレーションツール
```

## 基本的な使い方

### スキーマ定義

```typescript
import { defineSchema, field, table } from '@sdbk/core';

// テーブル定義
const userTable = table('user', {
  name: field.string(),
  email: field.string(),
  age: field.number().optional(),
  createdAt: field.datetime().default(() => new Date()),
});

// スキーマ全体
const schema = defineSchema({
  tables: [userTable],
});
```

### 型推論

```typescript
// テーブルからTypeScript型を生成
type User = InferTable<typeof userTable>;
// {
//   id: string;
//   name: string;
//   email: string;
//   age?: number;
//   createdAt: Date;
// }
```

### エンティティ操作

```typescript
import { createEntity, validateEntity } from '@sdbk/core';

// エンティティ作成（型安全）
const user = createEntity(userTable, {
  name: 'John',
  email: 'john@example.com',
});

// バリデーション
const result = validateEntity(userTable, data);
if (result.success) {
  console.log('Valid:', result.data);
} else {
  console.log('Errors:', result.errors);
}
```

## 型システム

### SurrealDB型マッピング

```typescript
// SurrealDB型 → TypeScript型
field.string()     // string
field.number()     // number
field.bool()       // boolean
field.datetime()   // Date
field.duration()   // Duration
field.array()      // T[]
field.object()     // Record<string, unknown>
field.record()     // RecordId
field.geometry()   // Geometry types
```

### RecordId型

```typescript
import { RecordId, parseRecordId } from '@sdbk/core';

// RecordIdの作成
const userId: RecordId<'user'> = 'user:john';

// パース
const { table, id } = parseRecordId(userId);
// table: 'user', id: 'john'

// 型安全なリレーション
const postTable = table('post', {
  title: field.string(),
  author: field.record('user'), // user:* のみ許可
});
```

### オプショナルとデフォルト

```typescript
const userTable = table('user', {
  // 必須フィールド
  name: field.string(),

  // オプショナル
  bio: field.string().optional(),

  // デフォルト値
  role: field.string().default('user'),

  // 計算デフォルト
  createdAt: field.datetime().default(() => new Date()),
});
```

## クエリビルダー（計画中: @sdbk/query）

```typescript
// 将来的な使用例
import { query } from '@sdbk/query';

// 型安全なクエリ
const users = await query(userTable)
  .where('age', '>', 18)
  .orderBy('name')
  .limit(10)
  .execute(db);

// 型推論: User[]
```

## 実用パターン

### プロジェクト構成

```
src/
├── db/
│   ├── schema.ts      # スキーマ定義
│   ├── tables/        # テーブル別定義
│   │   ├── user.ts
│   │   └── post.ts
│   └── types.ts       # 推論された型をエクスポート
├── repositories/      # リポジトリパターン
│   ├── user.ts
│   └── post.ts
└── index.ts
```

### スキーマファイル例

```typescript
// db/schema.ts
import { defineSchema } from '@sdbk/core';
import { userTable, postTable } from './tables';

export const schema = defineSchema({
  tables: [userTable, postTable],
});

// 型エクスポート
export type { User, Post } from './types';
```

### テーブル定義例

```typescript
// db/tables/user.ts
import { table, field } from '@sdbk/core';

export const userTable = table('user', {
  name: field.string(),
  email: field.string(),
  password: field.string(),
  role: field.enum(['admin', 'user', 'guest']).default('user'),
  profile: field.object({
    bio: field.string().optional(),
    avatar: field.string().optional(),
  }).optional(),
  createdAt: field.datetime().default(() => new Date()),
  updatedAt: field.datetime(),
});
```

### リポジトリパターンとの統合

```typescript
// repositories/user.ts
import { Surreal } from 'surrealdb';
import { userTable, User } from '../db';
import { validateEntity, InferCreate } from '@sdbk/core';

export class UserRepository {
  constructor(private db: Surreal) {}

  async create(data: InferCreate<typeof userTable>): Promise<User> {
    // 型安全なバリデーション
    const validated = validateEntity(userTable, data);
    if (!validated.success) {
      throw new Error(validated.errors.join(', '));
    }

    const [user] = await this.db.create<User>('user', validated.data);
    return user;
  }

  async findById(id: string): Promise<User | null> {
    return await this.db.select<User>(`user:${id}`);
  }
}
```

## 公式SurrealDB SDKとの違い

| 機能 | 公式SDK (surrealdb) | sdbk |
|------|---------------------|------|
| 基本CRUD | ✅ | ✅（ラッパー経由） |
| 型推論 | 手動定義 | 自動生成 |
| スキーマ定義 | なし | ✅ |
| バリデーション | なし | ✅ |
| クエリビルダー | なし | 計画中 |
| マイグレーション | なし | 計画中 |

### 併用パターン

```typescript
// 公式SDKで接続
import { Surreal } from 'surrealdb';
// sdbkで型定義
import { userTable, User } from './db';
import { validateEntity } from '@sdbk/core';

const db = new Surreal();
await db.connect('ws://localhost:8000/rpc');

// sdbkの型とバリデーションを活用
const userData = {
  name: 'John',
  email: 'john@example.com',
};

const validated = validateEntity(userTable, userData);
if (validated.success) {
  // 公式SDKで操作
  const [user] = await db.create<User>('user', validated.data);
}
```

## 開発

### セットアップ

```bash
git clone https://github.com/veskel01/sdbk.git
cd sdbk

# 依存関係インストール
bun install

# ビルド
bun run build

# テスト
bun run test

# リント
bun run lint

# フォーマット
bun run format
```

### プロジェクト構造

```
sdbk/
├── packages/
│   └── core/          # コア型定義
├── scripts/           # ビルドスクリプト
└── turbo.json         # Turbo設定
```

## リソース

- **GitHub**: https://github.com/Veskel01/sdbk
- **Issues**: https://github.com/Veskel01/sdbk/issues
- **SurrealDB公式**: https://surrealdb.com/docs

## ユースケース

### いつsdbkを使うべきか

- TypeScriptプロジェクトで型安全なスキーマ定義が必要
- コンパイル時の型検証を活用したい
- スキーマ駆動開発を行いたい
- バリデーションロジックを一元化したい

### 公式SDKのみで十分な場合

- シンプルなCRUD操作のみ
- 動的なスキーマを扱う
- ランタイムのみの型チェックで十分
