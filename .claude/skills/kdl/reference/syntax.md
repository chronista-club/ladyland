# KDL構文リファレンス

KDL v2.0の完全な構文リファレンスです。

## ノード

### 基本形式

```
node-name [arguments...] [properties...] [children]
```

### 例

```kdl
// 引数のみ
title "Hello, World"

// 複数引数
bookmarks 12 15 188 1234

// 引数とプロパティ
author "Alex Monad" email="alex@example.com" active=#true

// 子ノード
parent {
    child1
    child2 "arg"
}
```

## 識別子（ノード名・プロパティ名）

### 非引用符識別子

以下の文字で始まる: `a-z`, `A-Z`, `_`, または非ASCII Unicode

以下の文字を含む: 上記 + `0-9`, `-`

```kdl
my-node
_private
日本語ノード
```

### 引用符識別子

特殊文字を含む場合は引用符が必要:

```kdl
"node with spaces"
"node/with/slashes"
```

## 値（引数・プロパティ値）

### 文字列

```kdl
// 引用符付き
name "Hello, World"

// エスケープシーケンス
escaped "line1\nline2\ttab"

// 生文字列（エスケープなし）
path #"C:\Users\name"#
path ##"contains #"##

// 複数行
text """
    first line
    second line
    """
```

**エスケープシーケンス**:
- `\n` - 改行
- `\t` - タブ
- `\\` - バックスラッシュ
- `\"` - ダブルクォート
- `\u{XXXX}` - Unicode

### 数値

```kdl
// 整数
count 42
negative -100

// 浮動小数点
pi 3.14159
scientific 1.0e10

// 16進数
hex 0xDEADBEEF

// 8進数
octal 0o755

// 2進数
binary 0b1010

// アンダースコア区切り
big 1_000_000

// 特殊値
infinity #inf
neg-infinity #-inf
not-a-number #nan
```

### ブール値

```kdl
enabled #true
disabled #false
```

### Null

```kdl
value #null
```

## プロパティ

`key=value` 形式:

```kdl
node prop1="value1" prop2=123 prop3=#true

// 複数行
node \
    prop1="value1" \
    prop2="value2"
```

## コメント

### 行コメント

```kdl
// これはコメント
node "value" // 行末コメント
```

### ブロックコメント

```kdl
/* ブロックコメント */

/*
 * 複数行
 * コメント
 */

/* ネスト /* 可能 */ */
```

### スラッシュダッシュ

ノードや引数をコメントアウト:

```kdl
/- ignored-node "this is skipped"

node /- "skipped-arg" "included-arg"

node prop=1 /- skipped-prop=2 other-prop=3
```

## 子ノード

`{ }` で囲む:

```kdl
parent {
    child1 "arg"
    child2 {
        grandchild
    }
}

// 同一行
parent { child "arg" }
```

## 行継続

バックスラッシュで改行をエスケープ:

```kdl
very-long-node \
    "argument1" \
    "argument2" \
    prop1="value1" \
    prop2="value2"
```

## ノード終端

- 改行
- セミコロン `;`
- ファイル終了
- 子ブロック終了 `}`

```kdl
node1; node2; node3

// 同じ意味
node1
node2
node3
```

## 型アノテーション

値に型を付与:

```kdl
date (date)"2024-01-15"
size (u32)1024
```

## ベストプラクティス

1. **インデント**: スペース4つを推奨
2. **引用符**: 特殊文字がなくても文字列は引用符推奨
3. **改行**: 長いノードは `\` で分割
4. **コメント**: `//` を基本に、`/-` でノード無効化
