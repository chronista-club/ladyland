//! rigcheck — 機材点検ツール
//!
//! 接続されている MIDI ポートとオーディオ I/O を一覧し、
//! **想定している機材構成と照合**する。
//!
//! ライブ本番前に 1 コマンドで「4台とも認識されているか」「音の出口が
//! LiveTrak になっているか」を確認するのが目的。
//! 単なる一覧ではなく照合結果を出すことで、点検が判断ではなく確認になる。
//!
//! ```text
//! cargo run --bin rigcheck
//! ```
//!
//! 将来的に想定機材リストは KDL preset（design/04 の「焼く」層）から
//! 読み込む。現時点ではコード内の `EXPECTED_*` を単一の情報源とする。

use cortex_audio::devices::{list_devices, AudioDeviceInfo, Direction};
use cortex_midi::MidiHandler;

/// 想定している MIDI 機材（表示名, ポート名の照合パターン）
///
/// 1台の機材が複数ポートを見せる点に注意（実測）:
/// - Keystage → "Keystage KBD/CTRL"（鍵盤）と "Keystage DAW IN"（DAW制御）
/// - L6max    → MIDI I/O / Mixer Control / for L6 Editor の3つ
/// - X-Touch  → INT / EXT
///
/// したがって照合では**マッチした全ポート**を表示する。
/// 実際にどのポートを掴むかはルーティング設定側の判断であり、
/// ここではその判断材料を出すことに徹する。
const EXPECTED_MIDI: &[(&str, &str)] = &[
    ("Keystage", "keystage"),
    ("LPD8", "lpd8"),
    ("ROTO-CONTROL", "roto"),
    ("FGDP-50", "fgdp"),
];

/// 想定している音声の出口（表示名, デバイス名の照合パターン）
///
/// 実機では "LiveTrak" ではなく **"ZOOM L6max"** として見える（実測で判明）。
const EXPECTED_AUDIO_OUT: (&str, &str) = ("ZOOM L6max", "l6max");

fn main() {
    println!();
    println!("=== cortex rigcheck — 機材点検 ===");
    println!();

    let midi_in = MidiHandler::list_ports().unwrap_or_else(|e| {
        eprintln!("MIDI 入力の列挙に失敗: {}", e);
        Vec::new()
    });
    let midi_out = MidiHandler::list_output_ports().unwrap_or_else(|e| {
        eprintln!("MIDI 出力の列挙に失敗: {}", e);
        Vec::new()
    });

    print_ports("MIDI 入力", &midi_in);
    print_ports("MIDI 出力", &midi_out);

    let audio_out = list_devices(Direction::Output).unwrap_or_else(|e| {
        eprintln!("オーディオ出力の列挙に失敗: {}", e);
        Vec::new()
    });
    let audio_in = list_devices(Direction::Input).unwrap_or_else(|e| {
        eprintln!("オーディオ入力の列挙に失敗: {}", e);
        Vec::new()
    });

    print_audio("オーディオ出力（Mac → 機材）", &audio_out);
    print_audio("オーディオ入力（機材 → Mac）", &audio_in);

    print_verification(&midi_in, &audio_out);
}

fn print_ports(title: &str, ports: &[String]) {
    println!("▼ {} ({})", title, ports.len());
    if ports.is_empty() {
        println!("    (なし)");
    }
    for (i, name) in ports.iter().enumerate() {
        println!("    {}. {}", i + 1, name);
    }
    println!();
}

fn print_audio(title: &str, devices: &[AudioDeviceInfo]) {
    println!("▼ {} ({})", title, devices.len());
    if devices.is_empty() {
        println!("    (なし)");
    }
    for d in devices {
        let mark = if d.is_default { "★" } else { "-" };
        let default_tag = if d.is_default { "  [OS既定]" } else { "" };
        println!("  {} {}{}", mark, d.name, default_tag);

        match d.default_config {
            Some((ch, sr)) => println!("      既定設定: {}ch @ {} Hz", ch, sr),
            None => println!("      既定設定: 取得できません"),
        }
        println!("      最大チャンネル数: {}", d.max_channels());

        for r in &d.supported {
            let rate = if r.min_sample_rate == r.max_sample_rate {
                format!("{} Hz", r.min_sample_rate)
            } else {
                format!("{}-{} Hz", r.min_sample_rate, r.max_sample_rate)
            };
            println!("      対応: {}ch {} {}", r.channels, r.sample_format, rate);
        }
    }
    println!();
}

/// 想定機材と実機の照合
fn print_verification(midi_in: &[String], audio_out: &[AudioDeviceInfo]) {
    println!("▼ 想定機材との照合");

    let mut missing = 0;

    for (label, pattern) in EXPECTED_MIDI {
        let matched = find_ports(midi_in, pattern);
        if matched.is_empty() {
            println!("    [MISS] {:<14} → 見つかりません", label);
            missing += 1;
            continue;
        }
        println!("    [OK]   {:<14} → \"{}\"", label, matched[0]);
        // 同一機材の別ポート（DAW制御用など）も判断材料として見せる
        for extra in &matched[1..] {
            println!("           {:<14}   \"{}\" (同一機材の別ポート)", "", extra);
        }
    }

    let (audio_label, audio_pattern) = EXPECTED_AUDIO_OUT;
    match audio_out
        .iter()
        .find(|d| d.name.to_lowercase().contains(audio_pattern))
    {
        Some(d) => {
            println!(
                "    [OK]   {:<14} → \"{}\" (最大 {}ch){}",
                audio_label,
                d.name,
                d.max_channels(),
                if d.is_default { "" } else { "  ※OS既定ではない" }
            );
            if !d.is_default {
                println!("           → 音声はこのデバイスへ明示指定が必要");
            }
        }
        None => {
            println!("    [MISS] {:<14} → 見つかりません", audio_label);
            missing += 1;
        }
    }

    println!();
    if missing == 0 {
        println!("結果: 想定機材すべて認識 OK");
    } else {
        println!("結果: {} 件が未検出（電源・USB接続を確認）", missing);
    }
    println!();
}

/// ポート名の部分一致検索（大文字小文字を無視）。マッチした全件を返す。
///
/// 1台の機材が複数ポートを見せるため、最初の1件で打ち切らない。
fn find_ports<'a>(ports: &'a [String], pattern: &str) -> Vec<&'a str> {
    ports
        .iter()
        .filter(|p| p.to_lowercase().contains(pattern))
        .map(|s| s.as_str())
        .collect()
}
