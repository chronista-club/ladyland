//! ビルド時刻をバージョンへ焼き込む — Ladyland の「同梱 fieldd と動作中
//! fieldd の同一性判定」（design/07 の自動アプデ）は文字列の完全一致で行う。
//! pkg version（0.1.0）だけでは再ビルドを区別できないため、ビルド時刻で補う。

use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("時計が UNIX epoch より前")
        .as_secs();
    println!("cargo:rustc-env=FIELDD_BUILD_TS={ts}");
    // ソースか schema が変わったら焼き直す（= 別バージョンになる）
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=schemas");
}
