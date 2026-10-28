//! 整曲响度分析（ReplayGain 2.0）：BASS 解码流喂 EBU R128，算出建议增益。
//!
//! 独立于引擎线程：解码流不需要输出设备，也不用等引擎就绪，
//! 分析期间暂停 / 跳转等播放命令不受影响。

use super::{BASS_SAMPLE_FLOAT, BASS_STREAM_DECODE, BASS_STREAM_PRESCAN, BASS_UNICODE};
use crate::bass::api::{dll_dir, last_error, wide, Api, BassChannelInfo};
use anyhow::{anyhow, bail, Result};
use std::ffi::c_void;
use std::path::Path;

/// ReplayGain 2.0 的目标响度（LUFS）；增益 = 目标 − 实测积分响度
const TARGET_LUFS: f64 = -18.0;

/// 分析整曲，返回建议增益（dB），夹取 ±24 dB
pub(super) fn analyze_gain(path: &str) -> Result<f64> {
    if path.is_empty() {
        bail!("音频路径为空");
    }
    // 解码前必须先 BASS_Init，而初始化和插件注册都由引擎负责——BASS 是进程级单例，
    // 这里自己 Init 会和引擎抢同一个实例（引擎随后 Init 直接撞 BASS_ERROR_ALREADY，
    // 整个播放不可用）。所以只确保引擎就绪，分析本身仍在本线程跑，不占引擎命令队列。
    //
    // 少了这一步时，凡是「首次播放之前」做的分析（如刚启动就批量补增益）都会
    // 以错误 8「BASS_Init 尚未成功调用」失败，插件缺失则是叠加的第二重原因。
    super::sender()?;

    let dir = dll_dir().ok_or_else(|| anyhow!("找不到 bass.dll"))?;
    let api = unsafe { Api::load(&dir) }?;

    let flags = BASS_UNICODE | BASS_SAMPLE_FLOAT | BASS_STREAM_PRESCAN | BASS_STREAM_DECODE;
    let wide = wide(Path::new(path));
    let handle =
        unsafe { (api.stream_create_file)(0, wide.as_ptr() as *const c_void, 0, 0, flags) };
    if handle == 0 {
        bail!("无法打开音频文件: {}", last_error(&api));
    }
    let loudness = measure(&api, handle);
    unsafe { (api.stream_free)(handle) };
    let loudness = loudness?;

    // 全静音时门限算法没有可用块，响度是 -inf：静音不需要归一
    if !loudness.is_finite() {
        return Ok(0.0);
    }
    Ok((TARGET_LUFS - loudness).clamp(-24.0, 24.0))
}

/// `BASS_ERROR_ENDED`：解码流读完时 `GetData` 以 -1 + 该错误码收尾，属正常结束
const BASS_ERROR_ENDED: i32 = 45;

/// 分析时接受的采样率上限（384 kHz，消费级 DXD 的上限）
const MAX_FREQ: u32 = 384_000;

/// 分析时接受的声道数上限（7.1）
const MAX_CHANS: u32 = 8;

fn measure(api: &Api, handle: u32) -> Result<f64> {
    let mut info = BassChannelInfo::default();
    if unsafe { (api.channel_get_info)(handle, &mut info) } == 0 {
        bail!("读取音频信息失败: {}", last_error(api));
    }
    // 损坏 / 伪造的文件头能让 GetInfo 回吐出离谱的采样率与声道数，
    // 直接拿来做缓冲分配会瞬间要几个 GB。夹在正常音频范围内：
    // 384 kHz 已是消费级 DXD 的上限，8 声道覆盖 7.1。
    if info.freq == 0 || info.freq > MAX_FREQ || info.chans == 0 || info.chans > MAX_CHANS {
        bail!(
            "音频参数异常（{} Hz / {} 声道），跳过分析",
            info.freq,
            info.chans
        );
    }
    let mut meter = ebur128::EbuR128::new(info.chans, info.freq, ebur128::Mode::I)
        .map_err(|e| anyhow!("初始化响度表失败: {e:?}"))?;

    // 一次喂约 100 ms 的样本
    let mut buf = vec![0.0f32; info.freq as usize * info.chans as usize / 10];
    loop {
        let got = unsafe {
            (api.channel_get_data)(
                handle,
                buf.as_mut_ptr() as *mut c_void,
                (buf.len() * 4) as u32,
            )
        };
        // 返回 -1：读完（错误码 45 = BASS_ERROR_ENDED）或真的出错
        if got == u32::MAX {
            if unsafe { (api.error_get_code)() } == BASS_ERROR_ENDED {
                break;
            }
            bail!("解码失败: {}", last_error(api));
        }
        if got == 0 {
            break;
        }
        meter
            .add_frames_f32(&buf[..got as usize / 4])
            .map_err(|e| anyhow!("响度统计失败: {e:?}"))?;
    }
    meter
        .loudness_global()
        .map_err(|e| anyhow!("响度计算失败: {e:?}"))
}
