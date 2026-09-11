//! macOS システム音量制御 (CoreAudio API)
//!
//! CoreAudio の AudioObject API を直接使い、Float32 精度で音量を制御する。
//! osascript (整数 0-100) と異なり、0.0〜1.0 の連続値で細かい調整が可能。

use std::process::Command;

// ── CoreAudio FFI ──────────────────────────────────────────

#[allow(non_upper_case_globals, non_camel_case_types, non_snake_case, dead_code)]
mod ffi {
    use std::os::raw::c_void;

    pub type OSStatus = i32;
    pub type AudioObjectID = u32;
    pub type AudioObjectPropertySelector = u32;
    pub type AudioObjectPropertyScope = u32;
    pub type AudioObjectPropertyElement = u32;

    pub const kAudioHardwareNoError: OSStatus = 0;
    pub const kAudioObjectSystemObject: AudioObjectID = 1;

    // Property selectors
    pub const kAudioHardwarePropertyDefaultOutputDevice: AudioObjectPropertySelector = 0x644F7574; // 'dOut'
    pub const kAudioDevicePropertyVolumeScalar: AudioObjectPropertySelector = 0x766F6C6D; // 'volm'
    pub const kAudioDevicePropertyMute: AudioObjectPropertySelector = 0x6D757465; // 'mute'

    // Scopes
    pub const kAudioObjectPropertyScopeGlobal: AudioObjectPropertyScope = 0x676C6F62; // 'glob'
    pub const kAudioDevicePropertyScopeOutput: AudioObjectPropertyScope = 0x6F757470; // 'outp'

    // Element
    pub const kAudioObjectPropertyElementMain: AudioObjectPropertyElement = 0;

    #[repr(C)]
    pub struct AudioObjectPropertyAddress {
        pub mSelector: AudioObjectPropertySelector,
        pub mScope: AudioObjectPropertyScope,
        pub mElement: AudioObjectPropertyElement,
    }

    #[link(name = "CoreAudio", kind = "framework")]
    extern "C" {
        pub fn AudioObjectGetPropertyData(
            inObjectID: AudioObjectID,
            inAddress: *const AudioObjectPropertyAddress,
            inQualifierDataSize: u32,
            inQualifierData: *const c_void,
            ioDataSize: *mut u32,
            outData: *mut c_void,
        ) -> OSStatus;

        pub fn AudioObjectSetPropertyData(
            inObjectID: AudioObjectID,
            inAddress: *const AudioObjectPropertyAddress,
            inQualifierDataSize: u32,
            inQualifierData: *const c_void,
            inDataSize: u32,
            inData: *const c_void,
        ) -> OSStatus;
    }
}

// ── Public API ─────────────────────────────────────────────

/// 現在の音量状態
#[derive(Debug, Clone)]
pub struct VolumeState {
    /// 音量 (0.0〜1.0)
    pub volume: f32,
    /// ミュート状態
    pub muted: bool,
    /// 出力デバイス名
    pub output_name: String,
}

impl VolumeState {
    /// Wire Protocol の StateUpdate payload にエンコード
    ///
    /// ```text
    /// Byte 0-3:   volume (f32 BE, 0.0-1.0)
    /// Byte 4:     muted (u8, 0=unmuted, 1=muted)
    /// Byte 5:     output_name_len (u8)
    /// Byte 6..:   output_name (UTF-8, max 32 bytes)
    /// ```
    pub fn to_payload(&self) -> Vec<u8> {
        let name_bytes = self.output_name.as_bytes();
        let name_len = name_bytes.len().min(32) as u8;
        let mut payload = Vec::with_capacity(6 + name_len as usize);
        payload.extend_from_slice(&self.volume.to_be_bytes());
        payload.push(if self.muted { 1 } else { 0 });
        payload.push(name_len);
        payload.extend_from_slice(&name_bytes[..name_len as usize]);
        payload
    }

    /// Wire Protocol payload からデコード
    pub fn from_payload(payload: &[u8]) -> Option<Self> {
        if payload.len() < 6 {
            return None;
        }
        let volume = f32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
        let muted = payload[4] != 0;
        let name_len = payload[5] as usize;
        let output_name = if payload.len() >= 6 + name_len {
            String::from_utf8_lossy(&payload[6..6 + name_len]).to_string()
        } else {
            "Unknown".to_string()
        };
        Some(Self {
            volume,
            muted,
            output_name,
        })
    }
}

/// macOS の現在の音量状態を取得
pub fn get_volume_state() -> VolumeState {
    VolumeState {
        volume: get_output_volume(),
        muted: get_output_muted(),
        output_name: get_output_device_name(),
    }
}

/// 音量を設定 (0.0〜1.0)
pub fn set_output_volume(volume: f32) {
    let vol = volume.clamp(0.0, 1.0);
    let device = default_output_device();
    if device == 0 {
        return;
    }

    // Try master (element 0) first, then per-channel (1, 2)
    for element in [0, 1, 2] {
        let address = ffi::AudioObjectPropertyAddress {
            mSelector: ffi::kAudioDevicePropertyVolumeScalar,
            mScope: ffi::kAudioDevicePropertyScopeOutput,
            mElement: element,
        };
        unsafe {
            ffi::AudioObjectSetPropertyData(
                device,
                &address,
                0,
                std::ptr::null(),
                std::mem::size_of::<f32>() as u32,
                &vol as *const f32 as *const std::os::raw::c_void,
            );
        }
    }
}

/// ミュート切替
pub fn toggle_mute() {
    let muted = get_output_muted();
    set_mute(!muted);
}

/// 音量を delta 分調整 (±)
///
/// `step` は 1 delta あたりの変化量 (例: 0.01 = 1%)。
/// 戻り値は調整後の音量 (0.0〜1.0)。
pub fn adjust_volume(delta: i8, step: f32) -> f32 {
    let current = get_output_volume();
    let new_vol = (current + delta as f32 * step).clamp(0.0, 1.0);
    set_output_volume(new_vol);
    new_vol
}

// ── CoreAudio 内部ヘルパー ─────────────────────────────────

fn default_output_device() -> ffi::AudioObjectID {
    let address = ffi::AudioObjectPropertyAddress {
        mSelector: ffi::kAudioHardwarePropertyDefaultOutputDevice,
        mScope: ffi::kAudioObjectPropertyScopeGlobal,
        mElement: ffi::kAudioObjectPropertyElementMain,
    };

    let mut device: ffi::AudioObjectID = 0;
    let mut size = std::mem::size_of::<ffi::AudioObjectID>() as u32;

    let status = unsafe {
        ffi::AudioObjectGetPropertyData(
            ffi::kAudioObjectSystemObject,
            &address,
            0,
            std::ptr::null(),
            &mut size,
            &mut device as *mut ffi::AudioObjectID as *mut std::os::raw::c_void,
        )
    };

    if status != ffi::kAudioHardwareNoError {
        tracing::error!("CoreAudio: failed to get default output device (status={})", status);
        return 0;
    }
    device
}

fn get_output_volume() -> f32 {
    let device = default_output_device();
    if device == 0 {
        return 0.5;
    }

    // Try master (element 0) first, then channel 1 (left)
    for element in [0, 1] {
        let address = ffi::AudioObjectPropertyAddress {
            mSelector: ffi::kAudioDevicePropertyVolumeScalar,
            mScope: ffi::kAudioDevicePropertyScopeOutput,
            mElement: element,
        };

        let mut volume: f32 = 0.5;
        let mut size = std::mem::size_of::<f32>() as u32;

        let status = unsafe {
            ffi::AudioObjectGetPropertyData(
                device,
                &address,
                0,
                std::ptr::null(),
                &mut size,
                &mut volume as *mut f32 as *mut std::os::raw::c_void,
            )
        };

        if status == ffi::kAudioHardwareNoError {
            return volume;
        }
    }

    tracing::warn!("CoreAudio: failed to get volume on all channels, fallback to 0.5");
    0.5
}

fn get_output_muted() -> bool {
    let device = default_output_device();
    if device == 0 {
        return false;
    }

    // Try master (element 0) first, then channel 1
    for element in [0, 1] {
        let address = ffi::AudioObjectPropertyAddress {
            mSelector: ffi::kAudioDevicePropertyMute,
            mScope: ffi::kAudioDevicePropertyScopeOutput,
            mElement: element,
        };

        let mut muted: u32 = 0;
        let mut size = std::mem::size_of::<u32>() as u32;

        let status = unsafe {
            ffi::AudioObjectGetPropertyData(
                device,
                &address,
                0,
                std::ptr::null(),
                &mut size,
                &mut muted as *mut u32 as *mut std::os::raw::c_void,
            )
        };

        if status == ffi::kAudioHardwareNoError {
            return muted != 0;
        }
    }
    false
}

fn set_mute(muted: bool) {
    let device = default_output_device();
    if device == 0 {
        return;
    }

    let value: u32 = if muted { 1 } else { 0 };

    // Try master (element 0) and per-channel (1, 2)
    for element in [0, 1, 2] {
        let address = ffi::AudioObjectPropertyAddress {
            mSelector: ffi::kAudioDevicePropertyMute,
            mScope: ffi::kAudioDevicePropertyScopeOutput,
            mElement: element,
        };
        unsafe {
            ffi::AudioObjectSetPropertyData(
                device,
                &address,
                0,
                std::ptr::null(),
                std::mem::size_of::<u32>() as u32,
                &value as *const u32 as *const std::os::raw::c_void,
            );
        }
    }
}

fn get_output_device_name() -> String {
    // SwitchAudioSource がある場合はそれを使う
    let output = Command::new("SwitchAudioSource")
        .args(["-c"])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        }
        _ => {
            // フォールバック: osascript
            let output = Command::new("osascript")
                .args(["-e", "do shell script \"system_profiler SPAudioDataType 2>/dev/null | grep 'Default Output' -A2 | tail -1 | sed 's/.*: //'\""])
                .output();
            match output {
                Ok(out) => {
                    let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if name.is_empty() {
                        "Unknown".to_string()
                    } else {
                        name
                    }
                }
                Err(_) => "Unknown".to_string(),
            }
        }
    }
}
