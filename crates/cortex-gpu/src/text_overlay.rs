//! テキストオーバーレイ
//!
//! glyphonを使用して画面上にテキスト（ファイル名・タイムスタンプ）を描画します。
//! REQ-VISUAL-003: テキストオーバーレイ

use glyphon::{
    Attrs, Buffer, Cache, Color, Family, FontSystem, Metrics, Resolution, Shaping, SwashCache,
    TextArea, TextAtlas, TextBounds, TextRenderer, Viewport,
};

/// テキストオーバーレイ
pub struct TextOverlay {
    font_system: FontSystem,
    swash_cache: SwashCache,
    viewport: Viewport,
    atlas: TextAtlas,
    text_renderer: TextRenderer,
    // テキストバッファ（再利用）
    filename_buffer: Buffer,
    timestamp_buffer: Buffer,
    // 状態
    current_filename: String,
    current_timestamp: String,
    width: u32,
    height: u32,
}

const FONT_SIZE: f32 = 24.0;
const LINE_HEIGHT: f32 = 28.0;
const PADDING: f32 = 16.0;

impl TextOverlay {
    /// 新しいテキストオーバーレイを作成
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        surface_format: wgpu::TextureFormat,
        width: u32,
        height: u32,
    ) -> Self {
        let mut font_system = FontSystem::new();
        let swash_cache = SwashCache::new();
        let cache = Cache::new(device);
        let viewport = Viewport::new(device, &cache);
        let mut atlas = TextAtlas::new(device, queue, &cache, surface_format);
        let text_renderer = TextRenderer::new(
            &mut atlas,
            device,
            wgpu::MultisampleState::default(),
            None,
        );

        let metrics = Metrics::new(FONT_SIZE, LINE_HEIGHT);

        let mut filename_buffer = Buffer::new(&mut font_system, metrics);
        filename_buffer.set_size(&mut font_system, Some(width as f32), Some(LINE_HEIGHT));

        let mut timestamp_buffer = Buffer::new(&mut font_system, metrics);
        timestamp_buffer.set_size(&mut font_system, Some(width as f32), Some(LINE_HEIGHT));

        Self {
            font_system,
            swash_cache,
            viewport,
            atlas,
            text_renderer,
            filename_buffer,
            timestamp_buffer,
            current_filename: String::new(),
            current_timestamp: String::new(),
            width,
            height,
        }
    }

    /// テキスト内容を更新（内容変更時のみバッファ更新）
    pub fn update(
        &mut self,
        filename: &str,
        timestamp_secs: f64,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
    ) {
        // ファイル名が変わった場合のみ更新
        if self.current_filename != filename {
            self.current_filename = filename.to_string();
            self.filename_buffer.set_text(
                &mut self.font_system,
                filename,
                &Attrs::new().family(Family::SansSerif),
                Shaping::Advanced,
                None,
            );
            self.filename_buffer
                .shape_until_scroll(&mut self.font_system, false);
        }

        // タイムスタンプを毎フレーム更新（MM:SS.ss）
        let total_secs = timestamp_secs;
        let minutes = (total_secs / 60.0) as u32;
        let seconds = total_secs % 60.0;
        let ts = format!("{:02}:{:05.2}", minutes, seconds);

        if self.current_timestamp != ts {
            self.current_timestamp = ts.clone();
            self.timestamp_buffer.set_text(
                &mut self.font_system,
                &ts,
                &Attrs::new().family(Family::Monospace),
                Shaping::Advanced,
                None,
            );
            self.timestamp_buffer
                .shape_until_scroll(&mut self.font_system, false);
        }

        // Viewport更新
        self.viewport.update(
            queue,
            Resolution {
                width: self.width,
                height: self.height,
            },
        );

        // テキストエリアを準備
        let filename_top = self.height as f32 - PADDING - LINE_HEIGHT * 2.0;
        let timestamp_top = self.height as f32 - PADDING - LINE_HEIGHT;

        let text_areas = [
            TextArea {
                buffer: &self.filename_buffer,
                left: PADDING,
                top: filename_top,
                scale: 1.0,
                bounds: TextBounds {
                    left: 0,
                    top: 0,
                    right: self.width as i32,
                    bottom: self.height as i32,
                },
                default_color: Color::rgb(255, 255, 255),
                custom_glyphs: &[],
            },
            TextArea {
                buffer: &self.timestamp_buffer,
                left: PADDING,
                top: timestamp_top,
                scale: 1.0,
                bounds: TextBounds {
                    left: 0,
                    top: 0,
                    right: self.width as i32,
                    bottom: self.height as i32,
                },
                default_color: Color::rgb(180, 180, 180),
                custom_glyphs: &[],
            },
        ];

        self.text_renderer
            .prepare(
                device,
                queue,
                &mut self.font_system,
                &mut self.atlas,
                &self.viewport,
                text_areas,
                &mut self.swash_cache,
            )
            .expect("Failed to prepare text");
    }

    /// レンダーパス内でテキストを描画（シェーダー描画の後に呼ぶ）
    pub fn render<'pass>(&'pass self, render_pass: &mut wgpu::RenderPass<'pass>) {
        self.text_renderer
            .render(&self.atlas, &self.viewport, render_pass)
            .expect("Failed to render text");
    }

    /// submit後にアトラスをトリム
    pub fn post_render(&mut self) {
        self.atlas.trim();
    }

    /// ウィンドウリサイズ時にサイズを更新
    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        self.filename_buffer
            .set_size(&mut self.font_system, Some(width as f32), Some(LINE_HEIGHT));
        self.timestamp_buffer
            .set_size(&mut self.font_system, Some(width as f32), Some(LINE_HEIGHT));
    }
}
