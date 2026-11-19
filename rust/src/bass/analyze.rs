//! 整曲响度分析（ReplayGain 2.0）：BASS 解码流喂 EBU R128，
//! 一次解码量出积分响度、采样峰值与真峰值。
//!
//! 增益不在这里算：参考响度与峰值类型都是用户设置（见 `api::player`），
//! 播放时按当前设置现算，改设置立刻生效，不用重跑整曲解码。
//!
//! 独立于引擎线程：解码流不需要输出设备，也不用等引擎就绪，
//! 分析期间暂停 / 跳转等播放命令不受影响。

use super::super::Loudness;
use super::{BASS_SAMPLE_FLOAT, BASS_STREAM_DECODE, BASS_STREAM_PRESCAN, BASS_UNICODE};
use crate::bass::api::{dll_dir, last_error, wide, Api, BassChannelInfo};
use anyhow::{anyhow, bail, Result};
use std::ffi::c_void;
use std::path::Path;

/// 分析整曲，量出积分响度与两种峰值（线性幅度）
pub(super) fn analyze_loudness(path: &str) -> Result<Loudness> {
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
    let measured = measure(&api, handle);
    unsafe { (api.stream_free)(handle) };
    measured
}

/// `BASS_ERROR_ENDED`：解码流读完时 `GetData` 以 -1 + 该错误码收尾，属正常结束
const BASS_ERROR_ENDED: i32 = 45;

/// 分析时接受的采样率上限（384 kHz，消费级 DXD 的上限）
const MAX_FREQ: u32 = 384_000;

/// 分析时接受的声道数上限（7.1）
const MAX_CHANS: u32 = 8;

fn measure(api: &Api, handle: u32) -> Result<Loudness> {
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
    // TRUE_PEAK 的位掩码已经包含 SAMPLE_PEAK，一次过采样把两种峰值都量出来
    let mode = ebur128::Mode::I | ebur128::Mode::TRUE_PEAK;
    let mut meter = ebur128::EbuR128::new(info.chans, info.freq, mode)
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

    let loudness = meter
        .loudness_global()
        .map_err(|e| anyhow!("响度计算失败: {e:?}"))?;
    // 峰值按声道各算一份，取最大：立体声左右声道峰值不同很常见
    let mut sample_peak: f64 = 0.0;
    let mut true_peak: f64 = 0.0;
    for channel in 0..info.chans {
        let sample = meter
            .sample_peak(channel)
            .map_err(|e| anyhow!("采样峰值计算失败: {e:?}"))?;
        let truth = meter
            .true_peak(channel)
            .map_err(|e| anyhow!("真峰值计算失败: {e:?}"))?;
        if sample.is_finite() && sample > sample_peak {
            sample_peak = sample;
        }
        if truth.is_finite() && truth > true_peak {
            true_peak = truth;
        }
    }

    // 全静音时门限算法没有可用块，响度是 -inf：静音不需要归一，按 0 记
    Ok(Loudness {
        loudness_lufs: if loudness.is_finite() { loudness } else { 0.0 },
        sample_peak,
        true_peak,
    })
}
