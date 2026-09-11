---
name: kdl
description: KDL (KDL Document Language) の構文とベストプラクティス
version: 1.0.0
---

# KDL Skill

KDL (KDL Document Language) を効果的に使用するためのガイドです。

## 概要

KDLは設定ファイル向けの人間にやさしいドキュメント言語です。XMLのようにノードベースでありながら、JSONのように簡潔です。

**公式サイト**: https://kdl.dev

## 基本構文

### ノード構造

```kdl
node-name "arg1" "arg2" key="value" {
    child-node "child-arg"
}
```

| 要素 | 説明 |
|------|------|
| ノード名 | 識別子（引用符なし可） |
| 引数 | 位置引数（順序が重要） |
| プロパティ | key=value 形式の名前付き引数 |
| 子ノード | `{ }` で囲む |

### データ型

| 型 | 例 | 説明 |
|----|-----|------|
| 文字列 | `"hello"` | ダブルクォート |
| 文字列（非引用符） | `hello` | 特殊文字なし |
| 生文字列 | `#"C:\path"#` | エスケープなし |
| 数値 | `123`, `3.14` | 整数・浮動小数点 |
| 16進数 | `0xdeadbeef` | 0x接頭辞 |
| ブール | `#true`, `#false` | **重要**: `true`ではなく`#true` |
| null | `#null` | #接頭辞 |

### コメント

```kdl
// 行コメント

/* ブロックコメント
   複数行OK
   ネスト可能 */

/- commented-node "this node is ignored"
```

**重要**: `/-` はノード全体をコメントアウトします。

## よくある間違い

### 1. ブール値の書き方

```kdl
// NG: KDL v2ではtrueは識別子
read_only=true

// OK: #接頭辞が必要
read_only=#true
```

### 2. プロパティ値の引用符忘れ

```kdl
// NG: 特殊文字を含む値は引用符が必要
url http://example.com

// OK
url "http://example.com"
```

### 2. ノード内のインラインコメント

```kdl
// NG: KDL 2.0では行末コメントに注意
port 8080  // comment after value

// OK: 改行してコメント
port 8080
// comment on separate line
```

### 3. 空白の扱い

```kdl
// NG: 引用符なしの空白
name Hello World

// OK
name "Hello World"
```

## FleetFlowでの使用

FleetFlowはKDLを設定ファイル形式として採用しています。

### 基本パターン

```kdl
project "my-project"

stage "local" {
    service "db"
    service "app"
}

service "db" {
    image "postgres"
    version "16"
    ports {
        port host=5432 container=5432
    }
    env {
        POSTGRES_PASSWORD "secret"
    }
}
```

### ポイント

1. **プロジェクト名**: 必須、最初に宣言
2. **ステージ**: 環境ごとにサービスをグループ化
3. **サービス**: イメージ、ポート、環境変数を定義
4. **プロパティ形式**: `key=value` で名前付き引数

## バリデーション

### FleetFlowでの検証

```bash
fleetflow validate
```

### 構文チェックのコツ

1. すべての文字列値を引用符で囲む
2. 特殊文字（`:`、`/`、`@`等）を含む値は必ず引用符
3. ブロックの`{}`は対応を確認
4. インデントは任意だが可読性のため推奨

## リファレンス

- [KDL構文詳細](reference/syntax.md)
- [FleetFlow連携](reference/fleetflow.md)

## 外部リンク

- [KDL公式](https://kdl.dev)
- [KDL仕様 (GitHub)](https://github.com/kdl-org/kdl)
- [KDL Playground](https://kdl.dev/play/)
