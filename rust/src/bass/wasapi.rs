//! BASSWASAPI / BASSmix 的最小 FFI 封装。
//!
//! 只有 [`crate::bass`] 的 Windows 实现会用到：`bass.dll` 自带的 DirectSound
//! 输出跟随系统混音格式，做不到独占；要独占必须用 `basswasapi.dll`，而独占
//! 模式不做重采样，素材格式因此需要 `bassmix.dll` 统一到设备格式。
//!
//! 结构体与常量取自 `third_party/bass/windows/{basswasapi,bassmix}.h`，
//! 不凭记忆拼签名。

use anyhow::{anyhow, Result};
use libloading::Library;
use std::ffi::c_void;
use std::path::Path;

/// 独占模式：设备只接受一种格式，由 `freq` / `chans` 指定
pub const WASAPI_EXCLUSIVE: u32 = 0x1;

/// 设备信息（对应 `BASS_WASAPI_INFO`）
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct WasapiInfo {
    pub initflags: u32,
    pub freq: u32,
    pub chans: u32,
    pub format: u32,
    pub buflen: u32,
    pub volmax: f32,
    pub volmin: f32,
    pub volstep: f32,
}

impl WasapiInfo {
    /// 设备格式的简短描述，用于设置页展示
    pub fn format_label(&self) -> &'static str {
        match self.format {
            0 => "32 位浮点",
            1 => "8 位整数",
            2 => "16 位整数",
            3 => "24 位整数",
            4 => "32 位整数",
            _ => "未知格式",
        }
    }
}

/// 初始化参数（对应 `BASS_WASAPI_Init` 的 device / freq / chans / flags / buffer）
#[derive(Clone, Copy, Debug)]
pub struct InitConfig {
    pub device: i32,
    pub freq: u32,
    pub chans: u32,
    pub flags: u32,
    pub buffer_secs: f32,
}

/// WASAPI 输出回调：往里写 `length` 字节，返回实际写入的字节数
pub type WasapiProc = unsafe extern "system" fn(*mut c_void, u32, *mut c_void) -> u32;

pub struct WasapiApi {
    _lib: Library,
    init: unsafe extern "system" fn(
        i32,
        u32,
        u32,
        u32,
        f32,
        f32,
        Option<WasapiProc>,
        *mut c_void,
    ) -> i32,
    free: unsafe extern "system" fn() -> i32,
    start: unsafe extern "system" fn() -> i32,
    stop: unsafe extern "system" fn(i32) -> i32,
    get_info: unsafe extern "system" fn(*mut WasapiInfo) -> i32,
}

impl WasapiApi {
    /// 加载 `basswasapi.dll`；文件不存在时返回错误，由调用方回落到共享输出
    pub unsafe fn load(dir: &Path) -> Result<Self> {
        let lib = Library::new(dir.join("basswasapi.dll"))
            .map_err(|e| anyhow!("加载 basswasapi.dll 失败: {e}"))?;
        Ok(Self {
            init: sym(&lib, "BASS_WASAPI_Init")?,
            free: sym(&lib, "BASS_WASAPI_Free")?,
            start: sym(&lib, "BASS_WASAPI_Start")?,
            stop: sym(&lib, "BASS_WASAPI_Stop")?,
            get_info: sym(&lib, "BASS_WASAPI_GetInfo")?,
            _lib: lib,
        })
    }

    /// `freq` / `chans` 传 0 表示沿用设备混音格式（最容易被独占接受）
    pub fn init(&self, config: InitConfig, proc: WasapiProc, user: *mut c_void) -> bool {
        unsafe {
            (self.init)(
                config.device,
                config.freq,
                config.chans,
                config.flags,
                config.buffer_secs,
                0.0,
                Some(proc),
                user,
            ) != 0
        }
    }

    pub fn free(&self) -> bool {
        unsafe { (self.free)() != 0 }
    }

    pub fn start(&self) -> bool {
        unsafe { (self.start)() != 0 }
    }

    pub fn stop(&self, reset: bool) -> bool {
        unsafe { (self.stop)(i32::from(reset)) != 0 }
    }

    pub fn info(&self) -> Option<WasapiInfo> {
        let mut info = WasapiInfo::default();
        let ok = unsafe { (self.get_info)(&mut info) };
        (ok != 0).then_some(info)
    }
}

/// BASSmix：把任意格式的解码流重采样到设备格式
pub struct MixApi {
    _lib: Library,
    stream_create: unsafe extern "system" fn(u32, u32, u32) -> u32,
    add_channel: unsafe extern "system" fn(u32, u32, u32) -> i32,
    channel_remove: unsafe extern "system" fn(u32) -> i32,
    channel_set_position: unsafe extern "system" fn(u32, u64, u32) -> i32,
}

impl MixApi {
    pub unsafe fn load(dir: &Path) -> Result<Self> {
        let lib = Library::new(dir.join("bassmix.dll"))
            .map_err(|e| anyhow!("加载 bassmix.dll 失败: {e}"))?;
        Ok(Self {
            stream_create: sym(&lib, "BASS_Mixer_StreamCreate")?,
            add_channel: sym(&lib, "BASS_Mixer_StreamAddChannel")?,
            channel_remove: sym(&lib, "BASS_Mixer_ChannelRemove")?,
            channel_set_position: sym(&lib, "BASS_Mixer_ChannelSetPosition")?,
            _lib: lib,
        })
    }

    /// 建一条与设备格式一致的混音流（解码流，不自己出声）
    pub fn stream_create(&self, freq: u32, chans: u32, flags: u32) -> u32 {
        unsafe { (self.stream_create)(freq, chans, flags) }
    }

    pub fn add_channel(&self, mixer: u32, channel: u32, flags: u32) -> bool {
        unsafe { (self.add_channel)(mixer, channel, flags) != 0 }
    }

    pub fn remove_channel(&self, channel: u32) -> bool {
        unsafe { (self.channel_remove)(channel) != 0 }
    }

    /// 源流挂在混音流上时必须走这个接口，`BASS_ChannelSetPosition` 不会同步混音器状态
    pub fn set_position(&self, channel: u32, pos: u64, mode: u32) -> bool {
        unsafe { (self.channel_set_position)(channel, pos, mode) != 0 }
    }
}

unsafe fn sym<T: Copy>(lib: &Library, name: &str) -> Result<T> {
    let mut raw = Vec::with_capacity(name.len() + 1);
    raw.extend_from_slice(name.as_bytes());
    raw.push(0);
    let symbol = lib
        .get::<T>(&*raw)
        .map_err(|e| anyhow!("缺少符号 {name}: {e}"))?;
    Ok(*symbol)
}
