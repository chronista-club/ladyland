//! Exercise the real GPU pipeline and text atlas without creating a window.
use cortex_gpu::{pipeline, shader, ShaderPipeline, ShaderUniforms, TextOverlay};
use wgpu::util::DeviceExt;

#[test]
fn renders_shader_and_text_to_readable_pixels() {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
    let adapter = pollster::block_on(instance.request_adapter(&Default::default())).unwrap();
    let (device, queue) = pollster::block_on(adapter.request_device(&Default::default())).unwrap();
    let format = wgpu::TextureFormat::Rgba8UnormSrgb;
    let layout = pipeline::create_uniform_bind_group_layout(&device);
    for source in [shader::GEOMETRIC_SHADER, shader::TEST_SHADER] {
        ShaderPipeline::from_wgsl(&device, source, format, &layout).unwrap();
    }
    let pipeline =
        ShaderPipeline::from_wgsl(&device, shader::TEST_SHADER, format, &layout).unwrap();
    let mut uniforms = ShaderUniforms::default();
    uniforms.resolution = [64.0, 96.0];
    let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("test uniforms"),
        contents: bytemuck::bytes_of(&uniforms),
        usage: wgpu::BufferUsages::UNIFORM,
    });
    let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: buffer.as_entire_binding(),
        }],
    });
    let mut text = TextOverlay::new(&device, &queue, format, 64, 96);
    text.update("test.wav", 1.25, &device, &queue);
    text.resize(64, 96);
    text.update("next.wav", 2.5, &device, &queue);
    let size = wgpu::Extent3d {
        width: 64,
        height: 96,
        depth_or_array_layers: 1,
    };
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: None,
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = texture.create_view(&Default::default());
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: 256 * 96,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&Default::default());
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(pipeline.render_pipeline());
        pass.set_bind_group(0, &group, &[]);
        pass.draw(0..3, 0..1);
        text.render(&mut pass);
    }
    encoder.copy_texture_to_buffer(
        texture.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &readback,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(256),
                rows_per_image: Some(96),
            },
        },
        size,
    );
    queue.submit([encoder.finish()]);
    let (tx, rx) = std::sync::mpsc::channel();
    readback
        .slice(..)
        .map_async(wgpu::MapMode::Read, move |result| tx.send(result).unwrap());
    device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
    rx.recv().unwrap().unwrap();
    let pixels = readback.slice(..).get_mapped_range().unwrap();
    assert!(pixels
        .chunks_exact(4)
        .any(|pixel| pixel[0] > 0 || pixel[1] > 0 || pixel[2] > 0));
    drop(pixels);
    readback.unmap();
}
