//! 1024 点实数 FFT，独占输出的频谱用它。
//!
//! 独占模式下不能对混音流取 BASS 的 FFT：那条流是解码流
//! （`BASS_STREAM_DECODE`），取数会把采样一并取走、解码位置跟着前进，
//! 和 WASAPI 回调抢数据 —— 实测会把播放拖成 1.64 倍速。BASS 没有
//! 「取 FFT 但不消费」的入口（`BASS_DATA_NOREMOVE` 只对录音通道有效），
//! 所以改成在回调里抄一份 PCM，这里自己算。
//!
//! 变换点数与 `BASS_DATA_FFT1024` 对齐，两边的分频映射才能共用一套。

use std::sync::OnceLock;

/// 变换点数（1024 = 2^10）
pub(super) const FFT_SIZE: usize = 1024;

/// 单边谱的 bin 数
pub(super) const FFT_BINS: usize = FFT_SIZE / 2;

/// Hann 窗与旋转因子：只在第一次调用时建一次，之后每帧直接查表
struct Tables {
    window: [f32; FFT_SIZE],
    cos: [f32; FFT_BINS],
    sin: [f32; FFT_BINS],
}

fn tables() -> &'static Tables {
    static TABLES: OnceLock<Tables> = OnceLock::new();
    TABLES.get_or_init(|| {
        let tau = std::f32::consts::PI * 2.0;
        let mut window = [0.0f32; FFT_SIZE];
        for (i, slot) in window.iter_mut().enumerate() {
            *slot = 0.5 - 0.5 * (tau * i as f32 / FFT_SIZE as f32).cos();
        }
        let mut cos = [0.0f32; FFT_BINS];
        let mut sin = [0.0f32; FFT_BINS];
        for k in 0..FFT_BINS {
            let angle = -tau * k as f32 / FFT_SIZE as f32;
            cos[k] = angle.cos();
            sin[k] = angle.sin();
        }
        Tables { window, cos, sin }
    })
}

/// 幅度谱（单边、Hann 窗、满幅正弦 ≈ 1）。
///
/// 归一化取 `4|X| / N`：Hann 窗的相干增益是 0.5，单边谱本来还要乘 2，
/// 合起来正好 4/N —— 满幅正弦在对应 bin 上是 1，与 BASS 的 FFT 同量纲，
/// 上层那段分频 + 提升不用区分数据来自哪条路。
pub(super) fn magnitude(samples: &[f32; FFT_SIZE]) -> [f32; FFT_BINS] {
    let table = tables();
    let mut re = [0.0f32; FFT_SIZE];
    let mut im = [0.0f32; FFT_SIZE];

    // 加窗 + 位反转重排（一次性完成，省一趟内存）
    for (i, sample) in samples.iter().enumerate() {
        let reversed = ((i as u32).reverse_bits() >> 22) as usize;
        re[reversed] = sample * table.window[i];
    }

    // 迭代式 radix-2 蝶形
    let mut size = 2;
    while size <= FFT_SIZE {
        let half = size / 2;
        let stride = FFT_SIZE / size;
        let mut base = 0;
        while base < FFT_SIZE {
            for k in 0..half {
                let tw = k * stride;
                let (wr, wi) = (table.cos[tw], table.sin[tw]);
                let a = base + k;
                let b = a + half;
                let tr = re[b] * wr - im[b] * wi;
                let ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
            base += size;
        }
        size *= 2;
    }

    let scale = 4.0 / FFT_SIZE as f32;
    let mut out = [0.0f32; FFT_BINS];
    for (k, bin) in out.iter_mut().enumerate() {
        *bin = scale * (re[k] * re[k] + im[k] * im[k]).sqrt();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 44.1k 采样率下的正弦，落点正好是 bin 100
    fn sine(amp: f32) -> [f32; FFT_SIZE] {
        let tau = std::f32::consts::PI * 2.0;
        let mut out = [0.0f32; FFT_SIZE];
        for (i, value) in out.iter_mut().enumerate() {
            *value = amp * (tau * 100.0 * i as f32 / FFT_SIZE as f32).sin();
        }
        out
    }

    #[test]
    fn full_scale_sine_reads_about_one() {
        let spec = magnitude(&sine(1.0));
        let peak = spec.iter().copied().fold(0.0f32, f32::max);
        assert!((peak - 1.0).abs() < 0.05, "满幅正弦应接近 1，实际 {peak}");
        assert!(
            spec[100] > 0.95,
            "能量应落在第 100 个 bin，实际 {}",
            spec[100]
        );
        assert!(spec[0] < 0.1 && spec[500] < 0.1, "其余 bin 应几乎没有能量");
    }

    #[test]
    fn half_amplitude_reads_half() {
        let spec = magnitude(&sine(0.5));
        let peak = spec.iter().copied().fold(0.0f32, f32::max);
        assert!((peak - 0.5).abs() < 0.05, "半幅正弦应接近 0.5，实际 {peak}");
    }

    #[test]
    fn silence_is_silent() {
        let spec = magnitude(&[0.0f32; FFT_SIZE]);
        assert!(spec.iter().all(|value| *value < 1e-6));
    }
}
