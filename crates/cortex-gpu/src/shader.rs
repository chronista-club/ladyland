//! シェーダー定義
//!
//! 組み込みシェーダーとユーティリティを提供します。
//! REQ-VISUAL-003: シェーダー管理

/// ジオメトリックシェーダー（デフォルト）
pub const GEOMETRIC_SHADER: &str = r#"
// ユニフォーム構造体
// 注: WGSLのuniform bufferでは配列要素に16バイトアライメントが必要
// そのため array<f32, N> ではなく vec4<f32> を使用
struct Uniforms {
    time: f32,
    resolution: vec2<f32>,
    delta_time: f32,
    rms: f32,
    bass: f32,
    mid: f32,
    high: f32,
    beat_intensity: f32,
    beat_count: f32,
    beat_interval: f32,
    time_since_beat: f32,
    // midi_cc[0-3] と midi_cc[4-7] を vec4 で表現
    midi_cc_0_3: vec4<f32>,
    midi_cc_4_7: vec4<f32>,
    midi_pitch_bend: f32,
    midi_mod_wheel: f32,
    scene_index: f32,
    scene_transition: f32,
    custom_params: vec4<f32>,
}

@group(0) @binding(0)
var<uniform> uniforms: Uniforms;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

// フルスクリーン三角形の頂点シェーダー
@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;

    // 大きな三角形でスクリーンをカバー
    let x = f32(i32(vertex_index) - 1);
    let y = f32(i32(vertex_index & 1u) * 2 - 1);

    out.position = vec4<f32>(x * 4.0, y * 4.0, 0.0, 1.0);
    out.uv = vec2<f32>(x * 2.0 + 0.5, 1.0 - (y * 2.0 + 0.5));

    return out;
}

// SDF: 円
fn sd_circle(p: vec2<f32>, r: f32) -> f32 {
    return length(p) - r;
}

// SDF: 正方形
fn sd_box(p: vec2<f32>, b: vec2<f32>) -> f32 {
    let d = abs(p) - b;
    return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0);
}

// 回転行列
fn rotate(angle: f32) -> mat2x2<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return mat2x2<f32>(c, -s, s, c);
}

// HSVからRGBへの変換
fn hsv2rgb(c: vec3<f32>) -> vec3<f32> {
    let p = abs(fract(c.xxx + vec3<f32>(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - vec3<f32>(3.0));
    return c.z * mix(vec3<f32>(1.0), clamp(p - vec3<f32>(1.0), vec3<f32>(0.0), vec3<f32>(1.0)), c.y);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let aspect = uniforms.resolution.x / uniforms.resolution.y;
    var uv = in.uv * 2.0 - 1.0;
    uv.x *= aspect;

    let time = uniforms.time;
    let bass = uniforms.bass * 3.0;
    let mid = uniforms.mid * 2.0;
    let high = uniforms.high * 1.5;
    let beat = uniforms.beat_intensity;

    // ビートで拡大
    let scale = 1.0 + beat * 0.3;
    uv /= scale;

    // 回転（時間とMIDI CCで制御）
    let rotation_speed = 0.2 + uniforms.midi_cc_0_3.x * 0.5;
    let rotation_matrix = rotate(time * rotation_speed);
    uv = rotation_matrix * uv;

    // 中心の円
    let circle_radius = 0.3 + bass * 0.2;
    let d_circle = sd_circle(uv, circle_radius);

    // 外側の正方形（リング）
    let n_rings = 4;
    var ring_color = vec3<f32>(0.0);

    for (var i = 0; i < n_rings; i++) {
        let fi = f32(i);
        let ring_scale = 0.5 + fi * 0.25;
        let ring_rotation = rotate(time * 0.1 * (fi + 1.0));
        let ring_uv = ring_rotation * uv;

        let box_size = vec2<f32>(ring_scale + mid * 0.1);
        let d_box = abs(sd_box(ring_uv, box_size)) - 0.02;

        let ring_glow = 0.02 / (abs(d_box) + 0.01);
        let hue = fract(fi * 0.2 + time * 0.1 + high * 0.5);
        ring_color += hsv2rgb(vec3<f32>(hue, 0.8, 1.0)) * ring_glow * (0.3 + beat * 0.5);
    }

    // 中心円のグロー
    let circle_glow = 0.05 / (abs(d_circle) + 0.01);
    let center_hue = fract(time * 0.05 + bass);
    let center_color = hsv2rgb(vec3<f32>(center_hue, 0.6, 1.0)) * circle_glow * (0.5 + bass);

    // 背景グラデーション
    let bg_color = vec3<f32>(0.02, 0.02, 0.05) * (1.0 + beat * 0.2);

    // 合成
    var final_color = bg_color + center_color + ring_color;

    // ビネット効果
    let vignette = 1.0 - length(in.uv - 0.5) * 0.8;
    final_color *= vignette;

    // ガンマ補正
    final_color = pow(final_color, vec3<f32>(0.8));

    return vec4<f32>(clamp(final_color, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
"#;

/// シンプルなテスト用シェーダー
pub const TEST_SHADER: &str = r#"
struct Uniforms {
    time: f32,
    resolution: vec2<f32>,
    delta_time: f32,
    rms: f32,
    bass: f32,
    mid: f32,
    high: f32,
    beat_intensity: f32,
    beat_count: f32,
    beat_interval: f32,
    time_since_beat: f32,
    midi_cc_0_3: vec4<f32>,
    midi_cc_4_7: vec4<f32>,
    midi_pitch_bend: f32,
    midi_mod_wheel: f32,
    scene_index: f32,
    scene_transition: f32,
    custom_params: vec4<f32>,
}

@group(0) @binding(0)
var<uniform> uniforms: Uniforms;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    let x = f32(i32(vertex_index) - 1);
    let y = f32(i32(vertex_index & 1u) * 2 - 1);
    out.position = vec4<f32>(x * 4.0, y * 4.0, 0.0, 1.0);
    out.uv = vec2<f32>(x * 2.0 + 0.5, 1.0 - (y * 2.0 + 0.5));
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = vec3<f32>(
        in.uv.x + uniforms.bass,
        in.uv.y + uniforms.mid,
        0.5 + sin(uniforms.time) * 0.5 + uniforms.high
    );
    return vec4<f32>(color, 1.0);
}
"#;

/// シェーダータイプ
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShaderType {
    /// ジオメトリックパターン
    Geometric,
    /// パーティクル
    Particle,
    /// フラクタル
    Fractal,
    /// テスト用
    Test,
    /// カスタム
    Custom,
}

impl ShaderType {
    /// 組み込みシェーダーのソースを取得
    pub fn source(&self) -> Option<&'static str> {
        match self {
            ShaderType::Geometric => Some(GEOMETRIC_SHADER),
            ShaderType::Test => Some(TEST_SHADER),
            _ => None,
        }
    }
}
