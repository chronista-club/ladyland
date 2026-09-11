//! GPUレンダラー
//!
//! wgpuを使用してシェーダーベースのビジュアルをレンダリングします。
//! REQ-VISUAL-001: GPUレンダリング

use std::sync::Arc;

use wgpu::util::DeviceExt;
use winit::window::Window;

use cortex_types::{WaveError, WaveResult};
use crate::shader_types::{RenderConfig, ShaderUniforms};

use crate::pipeline::ShaderPipeline;
use crate::text_overlay::TextOverlay;

/// GPUレンダラー
pub struct Renderer {
    surface: wgpu::Surface<'static>,
    device: Arc<wgpu::Device>,
    queue: Arc<wgpu::Queue>,
    config: wgpu::SurfaceConfiguration,
    pipeline: Option<ShaderPipeline>,
    uniform_buffer: wgpu::Buffer,
    uniform_bind_group: wgpu::BindGroup,
    uniforms: ShaderUniforms,
    render_config: RenderConfig,
    text_overlay: Option<TextOverlay>,
}

impl Renderer {
    /// 新しいレンダラーを作成
    pub async fn new(window: Arc<Window>, render_config: RenderConfig) -> WaveResult<Self> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });

        let surface = instance
            .create_surface(window.clone())
            .map_err(|e| WaveError::Graphics(format!("Failed to create surface: {}", e)))?;

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .map_err(|e| WaveError::Graphics(format!("No suitable GPU adapter found: {}", e)))?;

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("wave-generator device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::default(),
                trace: wgpu::Trace::Off,
                experimental_features: wgpu::ExperimentalFeatures::default(),
            })
            .await
            .map_err(|e| WaveError::Graphics(format!("Failed to create device: {}", e)))?;

        let device = Arc::new(device);
        let queue = Arc::new(queue);

        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = surface_caps
            .formats
            .iter()
            .find(|f| f.is_srgb())
            .copied()
            .unwrap_or(surface_caps.formats[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: render_config.width,
            height: render_config.height,
            present_mode: if render_config.vsync {
                wgpu::PresentMode::AutoVsync
            } else {
                wgpu::PresentMode::AutoNoVsync
            },
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };

        surface.configure(&device, &config);

        // ユニフォームバッファを作成
        let uniforms = ShaderUniforms::default();
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Uniform Buffer"),
            contents: bytemuck::cast_slice(&[uniforms]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let uniform_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("Uniform Bind Group Layout"),
                entries: &[wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                }],
            });

        let uniform_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Uniform Bind Group"),
            layout: &uniform_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: uniform_buffer.as_entire_binding(),
            }],
        });

        tracing::info!(
            "Renderer initialized: {}x{} @ {:?}",
            config.width,
            config.height,
            surface_format,
        );

        Ok(Self {
            surface,
            device,
            queue,
            config,
            pipeline: None,
            uniform_buffer,
            uniform_bind_group,
            uniforms,
            render_config,
            text_overlay: None,
        })
    }

    /// シェーダーパイプラインを設定
    pub fn set_pipeline(&mut self, pipeline: ShaderPipeline) {
        self.pipeline = Some(pipeline);
    }

    /// テキストオーバーレイを初期化
    pub fn initialize_text_overlay(&mut self) {
        let overlay = TextOverlay::new(
            &self.device,
            &self.queue,
            self.config.format,
            self.config.width,
            self.config.height,
        );
        self.text_overlay = Some(overlay);
        tracing::info!("Text overlay initialized");
    }

    /// テキストオーバーレイを更新
    pub fn update_text(&mut self, filename: &str, timestamp_secs: f64) {
        if let Some(ref mut overlay) = self.text_overlay {
            overlay.update(filename, timestamp_secs, &self.device, &self.queue);
        }
    }

    /// ユニフォームを更新
    pub fn update_uniforms(&mut self, uniforms: ShaderUniforms) {
        self.uniforms = uniforms;
        self.queue
            .write_buffer(&self.uniform_buffer, 0, bytemuck::cast_slice(&[self.uniforms]));
    }

    /// フレームをレンダリング
    pub fn render(&mut self) -> WaveResult<()> {
        let output = self
            .surface
            .get_current_texture()
            .map_err(|e| WaveError::Graphics(format!("Failed to get surface texture: {}", e)))?;

        let view = output
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Render Encoder"),
            });

        {
            let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Render Pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.0,
                            g: 0.0,
                            b: 0.0,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });

            if let Some(ref pipeline) = self.pipeline {
                render_pass.set_pipeline(pipeline.render_pipeline());
                render_pass.set_bind_group(0, &self.uniform_bind_group, &[]);
                render_pass.draw(0..3, 0..1); // フルスクリーン三角形
            }

            // テキストオーバーレイ描画
            if let Some(ref text_overlay) = self.text_overlay {
                text_overlay.render(&mut render_pass);
            }
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        output.present();

        // テキストアトラスのトリム
        if let Some(ref mut text_overlay) = self.text_overlay {
            text_overlay.post_render();
        }

        Ok(())
    }

    /// レンダリング結果をバッファに取得（動画エンコード用）
    pub fn render_to_buffer(&mut self) -> WaveResult<Vec<u8>> {
        let texture_desc = wgpu::TextureDescriptor {
            label: Some("Capture Texture"),
            size: wgpu::Extent3d {
                width: self.config.width,
                height: self.config.height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        };

        let texture = self.device.create_texture(&texture_desc);
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Capture Encoder"),
            });

        {
            let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Capture Render Pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });

            if let Some(ref pipeline) = self.pipeline {
                render_pass.set_pipeline(pipeline.render_pipeline());
                render_pass.set_bind_group(0, &self.uniform_bind_group, &[]);
                render_pass.draw(0..3, 0..1);
            }

            // テキストオーバーレイ描画（録画にもテキスト含む）
            if let Some(ref text_overlay) = self.text_overlay {
                text_overlay.render(&mut render_pass);
            }
        }

        // バッファにコピー
        let bytes_per_row = 4 * self.config.width;
        let padded_bytes_per_row = (bytes_per_row + 255) & !255;

        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Capture Buffer"),
            size: (padded_bytes_per_row * self.config.height) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_bytes_per_row),
                    rows_per_image: Some(self.config.height),
                },
            },
            texture_desc.size,
        );

        self.queue.submit(std::iter::once(encoder.finish()));

        // バッファを読み取り
        let buffer_slice = buffer.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        buffer_slice.map_async(wgpu::MapMode::Read, move |result| {
            tx.send(result).unwrap();
        });
        self.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
        rx.recv()
            .unwrap()
            .map_err(|e| WaveError::Graphics(format!("Failed to map buffer: {:?}", e)))?;

        let data = buffer_slice.get_mapped_range();

        // パディングを除去してRGBAデータを抽出
        let mut result = Vec::with_capacity((4 * self.config.width * self.config.height) as usize);
        for row in 0..self.config.height {
            let start = (row * padded_bytes_per_row) as usize;
            let end = start + (4 * self.config.width) as usize;
            result.extend_from_slice(&data[start..end]);
        }

        drop(data);
        buffer.unmap();

        Ok(result)
    }

    /// ウィンドウサイズ変更に対応
    pub fn resize(&mut self, width: u32, height: u32) {
        if width > 0 && height > 0 {
            self.config.width = width;
            self.config.height = height;
            self.surface.configure(&self.device, &self.config);
            self.uniforms.resolution = [width as f32, height as f32];
            if let Some(ref mut text_overlay) = self.text_overlay {
                text_overlay.resize(width, height);
            }
            tracing::info!("Renderer resized: {}x{}", width, height);
        }
    }

    /// デバイスを取得
    pub fn device(&self) -> &Arc<wgpu::Device> {
        &self.device
    }

    /// キューを取得
    pub fn queue(&self) -> &Arc<wgpu::Queue> {
        &self.queue
    }

    /// サーフェスフォーマットを取得
    pub fn surface_format(&self) -> wgpu::TextureFormat {
        self.config.format
    }
}
