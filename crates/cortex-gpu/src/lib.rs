//! cortex-gpu - GPU rendering + video encoding
//!
//! wgpuベースのGPUレンダリング、シェーダー管理、動画エンコードを提供します。
//!
//! ## 構成
//! - `renderer`: wgpuレンダラー
//! - `pipeline`: シェーダーパイプライン
//! - `shader`: WGSLシェーダー定義
//! - `shader_types`: GPU転送用データ構造（ShaderUniforms, RenderConfig, EncoderConfig）
//! - `encoder`: 動画エンコード（H.264/MP4）

pub mod encoder;
pub mod pipeline;
pub mod renderer;
pub mod shader;
pub mod shader_types;
pub mod text_overlay;

pub use encoder::VideoEncoder;
pub use pipeline::ShaderPipeline;
pub use renderer::Renderer;
pub use shader_types::{EncoderConfig, EncoderPreset, RenderConfig, ShaderUniforms, VideoCodec};
pub use text_overlay::TextOverlay;
