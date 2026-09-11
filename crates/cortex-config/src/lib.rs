//! wave-preset - KDL preset loading
//!
//! KDLフォーマットのプリセットファイルを読み込みます。
//!
//! ## プリセット構造
//! - シェーダー設定
//! - パラメータデフォルト値
//! - MIDIマッピング
//! - シーン定義
//!
//! REQ-PRESET-001: プリセット管理

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use cortex_types::{WaveError, WaveResult};

/// プリセット
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Preset {
    /// プリセット名
    pub name: String,
    /// 説明
    pub description: Option<String>,
    /// シェーダーファイルパス
    pub shader_path: Option<String>,
    /// インラインシェーダーソース
    pub shader_source: Option<String>,
    /// パラメータ
    pub parameters: HashMap<String, f32>,
    /// シーン定義
    pub scenes: Vec<Scene>,
    /// MIDIマッピング
    pub midi_mappings: HashMap<u8, String>,
}

impl Default for Preset {
    fn default() -> Self {
        Self {
            name: "Default".to_string(),
            description: None,
            shader_path: None,
            shader_source: None,
            parameters: HashMap::new(),
            scenes: vec![Scene::default()],
            midi_mappings: HashMap::new(),
        }
    }
}

/// シーン定義
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Scene {
    /// シーン名
    pub name: String,
    /// シェーダータイプ（組み込みシェーダー使用時）
    pub shader_type: Option<String>,
    /// カスタムシェーダーパス
    pub shader_path: Option<String>,
    /// パラメータオーバーライド
    pub parameters: HashMap<String, f32>,
    /// トランジション時間（秒）
    pub transition_time: f32,
}

impl Default for Scene {
    fn default() -> Self {
        Self {
            name: "Default Scene".to_string(),
            shader_type: Some("geometric".to_string()),
            shader_path: None,
            parameters: HashMap::new(),
            transition_time: 0.5,
        }
    }
}

/// プリセットローダー
pub struct PresetLoader;

impl PresetLoader {
    /// KDLファイルからプリセットを読み込み
    pub fn load_from_file<P: AsRef<Path>>(path: P) -> WaveResult<Preset> {
        let content = std::fs::read_to_string(path.as_ref())
            .map_err(|e| WaveError::Preset(format!("Failed to read file: {}", e)))?;

        Self::parse_kdl(&content)
    }

    /// KDL文字列をパース
    pub fn parse_kdl(content: &str) -> WaveResult<Preset> {
        let doc: PresetDocument = knuffel::parse("preset.kdl", content)
            .map_err(|e| WaveError::Preset(format!("Failed to parse KDL: {:?}", e)))?;

        Ok(doc.into_preset())
    }

    /// デフォルトプリセットを取得
    pub fn default_preset() -> Preset {
        Preset::default()
    }
}

/// KDL用の中間構造体
#[derive(Debug, knuffel::Decode)]
struct PresetDocument {
    #[knuffel(child, unwrap(argument))]
    name: Option<String>,
    #[knuffel(child, unwrap(argument))]
    description: Option<String>,
    #[knuffel(child, unwrap(argument))]
    shader: Option<String>,
    #[knuffel(children(name = "param"))]
    params: Vec<ParamNode>,
    #[knuffel(children(name = "scene"))]
    scenes: Vec<SceneNode>,
    #[knuffel(children(name = "midi"))]
    midi_mappings: Vec<MidiMappingNode>,
}

#[derive(Debug, knuffel::Decode)]
struct ParamNode {
    #[knuffel(argument)]
    name: String,
    #[knuffel(argument)]
    value: f64,
}

#[derive(Debug, knuffel::Decode)]
struct SceneNode {
    #[knuffel(argument)]
    name: String,
    #[knuffel(property(name = "shader_type"))]
    shader_type: Option<String>,
    #[knuffel(property(name = "shader_path"))]
    shader_path: Option<String>,
    #[knuffel(property)]
    transition: Option<f64>,
    #[knuffel(children(name = "param"))]
    params: Vec<ParamNode>,
}

#[derive(Debug, knuffel::Decode)]
struct MidiMappingNode {
    #[knuffel(argument)]
    cc: i64,
    #[knuffel(argument)]
    param: String,
}

impl PresetDocument {
    fn into_preset(self) -> Preset {
        let mut parameters = HashMap::new();
        for param in self.params {
            parameters.insert(param.name, param.value as f32);
        }

        let scenes = if self.scenes.is_empty() {
            vec![Scene::default()]
        } else {
            self.scenes
                .into_iter()
                .map(|s| {
                    let mut params = HashMap::new();
                    for param in s.params {
                        params.insert(param.name, param.value as f32);
                    }
                    Scene {
                        name: s.name,
                        shader_type: s.shader_type,
                        shader_path: s.shader_path,
                        parameters: params,
                        transition_time: s.transition.unwrap_or(0.5) as f32,
                    }
                })
                .collect()
        };

        let mut midi_mappings = HashMap::new();
        for mapping in self.midi_mappings {
            midi_mappings.insert(mapping.cc as u8, mapping.param);
        }

        Preset {
            name: self.name.unwrap_or_else(|| "Unnamed".to_string()),
            description: self.description,
            shader_path: None,
            shader_source: self.shader,
            parameters,
            scenes,
            midi_mappings,
        }
    }
}

/// プリセットマネージャー
pub struct PresetManager {
    presets: Vec<Preset>,
    current_index: usize,
}

impl PresetManager {
    /// 新しいマネージャーを作成
    pub fn new() -> Self {
        Self {
            presets: vec![Preset::default()],
            current_index: 0,
        }
    }

    /// プリセットを追加
    pub fn add_preset(&mut self, preset: Preset) {
        self.presets.push(preset);
    }

    /// ディレクトリからプリセットを読み込み
    pub fn load_from_directory<P: AsRef<Path>>(&mut self, dir: P) -> WaveResult<usize> {
        let mut count = 0;
        let entries = std::fs::read_dir(dir.as_ref())
            .map_err(|e| WaveError::Preset(format!("Failed to read directory: {}", e)))?;

        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map(|e| e == "kdl").unwrap_or(false) {
                match PresetLoader::load_from_file(&path) {
                    Ok(preset) => {
                        tracing::info!("Loaded preset: {}", preset.name);
                        self.presets.push(preset);
                        count += 1;
                    }
                    Err(e) => {
                        tracing::warn!("Failed to load {:?}: {}", path, e);
                    }
                }
            }
        }

        Ok(count)
    }

    /// 現在のプリセットを取得
    pub fn current(&self) -> &Preset {
        &self.presets[self.current_index]
    }

    /// 次のプリセットに切り替え
    pub fn next(&mut self) -> &Preset {
        self.current_index = (self.current_index + 1) % self.presets.len();
        self.current()
    }

    /// 前のプリセットに切り替え
    pub fn previous(&mut self) -> &Preset {
        if self.current_index == 0 {
            self.current_index = self.presets.len() - 1;
        } else {
            self.current_index -= 1;
        }
        self.current()
    }

    /// インデックスでプリセットを選択
    pub fn select(&mut self, index: usize) -> Option<&Preset> {
        if index < self.presets.len() {
            self.current_index = index;
            Some(self.current())
        } else {
            None
        }
    }

    /// プリセット数
    pub fn count(&self) -> usize {
        self.presets.len()
    }
}

impl Default for PresetManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_kdl() {
        let kdl = r#"
            name "Test Preset"
            description "A test preset"

            param "rotation_speed" 0.5
            param "color_intensity" 1.0

            scene "Scene 1" shader_type="geometric" transition=0.5 {
                param "glow" 1.5
            }

            midi 0 "rotation_speed"
            midi 1 "color_intensity"
        "#;

        let preset = PresetLoader::parse_kdl(kdl).unwrap();
        assert_eq!(preset.name, "Test Preset");
        assert_eq!(preset.scenes.len(), 1);
        assert_eq!(preset.scenes[0].name, "Scene 1");
        assert_eq!(preset.midi_mappings.get(&0), Some(&"rotation_speed".to_string()));
    }
}
