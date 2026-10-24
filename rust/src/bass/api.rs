//! BASS 的符号表与零散工具：函数指针、错误文案、DLL 查找、宽字符。
//!
//! 只被 `super`（Windows 实现的 `Engine`）使用。

use anyhow::{anyhow, Result};
use libloading::Library;
use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

pub(super) struct Api {
    pub(super) _lib: Library,
    pub(super) init: unsafe extern "system" fn(i32, u32, u32, *mut c_void, *const c_void) -> i32,
    pub(super) free: unsafe extern "system" fn() -> i32,
    pub(super) plugin_load: unsafe extern "system" fn(*const u16, u32) -> u32,
    pub(super) stream_create_file:
        unsafe extern "system" fn(u32, *const c_void, u64, u64, u32) -> u32,
    pub(super) stream_free: unsafe extern "system" fn(u32) -> i32,
    pub(super) channel_play: unsafe extern "system" fn(u32, i32) -> i32,
    pub(super) channel_pause: unsafe extern "system" fn(u32) -> i32,
    pub(super) channel_stop: unsafe extern "system" fn(u32) -> i32,
    pub(super) channel_is_active: unsafe extern "system" fn(u32) -> u32,
    pub(super) channel_set_position: unsafe extern "system" fn(u32, u64, u32) -> i32,
    pub(super) channel_get_position: unsafe extern "system" fn(u32, u32) -> u64,
    pub(super) channel_get_length: unsafe extern "system" fn(u32, u32) -> u64,
    pub(super) channel_set_attribute: unsafe extern "system" fn(u32, u32, f32) -> i32,
    pub(super) channel_get_data: unsafe extern "system" fn(u32, *mut c_void, u32) -> u32,
    pub(super) channel_set_fx: unsafe extern "system" fn(u32, u32, i32) -> u32,
    pub(super) channel_remove_fx: unsafe extern "system" fn(u32, u32) -> i32,
    pub(super) fx_set_parameters: unsafe extern "system" fn(u32, *mut c_void) -> i32,
    pub(super) channel_bytes2seconds: unsafe extern "system" fn(u32, u64) -> f64,
    pub(super) channel_seconds2bytes: unsafe extern "system" fn(u32, f64) -> u64,
    pub(super) error_get_code: unsafe extern "system" fn() -> i32,
}

impl Api {
    pub(super) unsafe fn load(dir: &Path) -> Result<Self> {
        let lib =
            Library::new(dir.join("bass.dll")).map_err(|e| anyhow!("加载 bass.dll 失败: {e}"))?;
        Ok(Self {
            init: sym(&lib, "BASS_Init")?,
            free: sym(&lib, "BASS_Free")?,
            plugin_load: sym(&lib, "BASS_PluginLoad")?,
            stream_create_file: sym(&lib, "BASS_StreamCreateFile")?,
            stream_free: sym(&lib, "BASS_StreamFree")?,
            channel_play: sym(&lib, "BASS_ChannelPlay")?,
            channel_pause: sym(&lib, "BASS_ChannelPause")?,
            channel_stop: sym(&lib, "BASS_ChannelStop")?,
            channel_is_active: sym(&lib, "BASS_ChannelIsActive")?,
            channel_set_position: sym(&lib, "BASS_ChannelSetPosition")?,
            channel_get_position: sym(&lib, "BASS_ChannelGetPosition")?,
            channel_get_length: sym(&lib, "BASS_ChannelGetLength")?,
            channel_set_attribute: sym(&lib, "BASS_ChannelSetAttribute")?,
            channel_get_data: sym(&lib, "BASS_ChannelGetData")?,
            channel_set_fx: sym(&lib, "BASS_ChannelSetFX")?,
            channel_remove_fx: sym(&lib, "BASS_ChannelRemoveFX")?,
            fx_set_parameters: sym(&lib, "BASS_FXSetParameters")?,
            channel_bytes2seconds: sym(&lib, "BASS_ChannelBytes2Seconds")?,
            channel_seconds2bytes: sym(&lib, "BASS_ChannelSeconds2Bytes")?,
            error_get_code: sym(&lib, "BASS_ErrorGetCode")?,
            _lib: lib,
        })
    }
}

unsafe fn sym<T: Copy>(lib: &Library, name: &str) -> Result<T> {
    let mut raw = Vec::with_capacity(name.len() + 1);
    raw.extend_from_slice(name.as_bytes());
    raw.push(0);
    let symbol = lib
        .get::<T>(&*raw)
        .map_err(|e| anyhow!("bass.dll 缺少符号 {name}: {e}"))?;
    Ok(*symbol)
}

pub(super) fn last_error(api: &Api) -> String {
    let code = unsafe { (api.error_get_code)() };
    format!("BASS 错误 {code}（{}）", error_text(code))
}

fn error_text(code: i32) -> &'static str {
    match code {
        1 => "内存不足",
        2 => "无法打开文件",
        3 => "找不到可用的音频设备",
        5 => "无效的句柄",
        // bass.h：14 = BASS_ERROR_ALREADY，46 = BASS_ERROR_BUSY
        14 => "对象已存在或已初始化",
        46 => "设备已被占用",
        6 => "不支持的采样格式",
        7 => "无效的位置",
        8 => "BASS_Init 尚未成功调用",
        17 => "文件不含音频数据",
        20 => "参数非法",
        23 => "设备编号非法",
        31 => "文件没有采样数据",
        37 => "请求的操作不可用",
        41 => "不支持的文件格式",
        44 => "缺少对应的解码器",
        _ => "未知错误",
    }
}

pub(super) fn dll_dir() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            candidates.push(parent.to_path_buf());
        }
    }
    // 开发/测试期：构建产物目录里没有 DLL 时回落到仓库内的 third_party
    candidates
        .push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../third_party/bass/windows/x64"));
    candidates
        .into_iter()
        .find(|dir| dir.join("bass.dll").is_file())
}

pub(super) fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}
