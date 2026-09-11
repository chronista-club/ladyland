//! デコーダーが生成する AudioFrame のサイズを実測するプローブ
//!
//! プラグインパイプラインの max_buffer_size（スクラッチバッファ）を超える
//! フレームが流れていないかの検証に使う。

use cortex_audio::AudioDecoder;

#[test]
fn probe_decoder_frame_size() {
    let path = std::path::Path::new("../../assets/Narrow Down.wav");
    if !path.exists() {
        println!("asset not found, skipping");
        return;
    }

    let mut decoder = AudioDecoder::from_file(path).expect("failed to open");
    let mut histogram = std::collections::BTreeMap::new();

    for _ in 0..100 {
        match decoder.decode_frame().expect("decode error") {
            Some(frame) => {
                *histogram.entry(frame.len()).or_insert(0usize) += 1;
            }
            None => break,
        }
    }

    println!("frame size histogram (size -> count): {:?}", histogram);
    let max_size = histogram.keys().max().copied().unwrap_or(0);
    println!("max frame size: {}", max_size);
}
