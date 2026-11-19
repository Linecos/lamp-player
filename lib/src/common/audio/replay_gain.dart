/// ReplayGain 增益计算（ReplayGain 2.0）。
///
/// 曲库里存的是**测量值**（积分响度 + 采样 / 真峰值），参考响度和峰值类型
/// 是用户设置：播放时在这里现算，改设置立刻生效，不用重跑整曲解码。
library;

import 'dart:math' as math;

/// 可选的参考响度（LUFS）：-23 偏保守、-18 是 ReplayGain 2.0 的默认口径、
/// -14 更贴近流媒体平台
const List<double> replayGainReferences = <double>[-23, -18, -14];

/// 默认参考响度（LUFS）
const double replayGainDefaultReference = -18;

/// 增益上限（dB）：离谱文件别把音量拉到失真
const double replayGainLimitDb = 24;

/// 按实测响度与峰值算增益（dB）。
///
/// [loudnessLufs] 是 EBU R128 积分响度，0 表示还没测过（静音也算 0）；
/// [peak] 是峰值**线性幅度**（1.0 = 满量程），0 表示未知、不做峰值限幅。
///
/// 增益 = 参考响度 − 实测响度；再把峰值压到「刚好 0 dBFS」为止
/// （`-20log10(peak)`），最后夹在 ±24 dB。峰值未知时与旧行为一致，只夹 ±24。
double replayGainForLoudness({
  required double loudnessLufs,
  required double peak,
  double referenceLufs = replayGainDefaultReference,
}) {
  if (!loudnessLufs.isFinite || loudnessLufs == 0) {
    return 0;
  }
  double gain = referenceLufs - loudnessLufs;
  if (peak.isFinite && peak > 0) {
    gain = math.min(gain, -20 * math.log(peak) / math.ln10);
  }
  return gain.clamp(-replayGainLimitDb, replayGainLimitDb).toDouble();
}

/// 把标签里的增益（约定按 -18 LUFS 参考）换算到 [referenceLufs]。
///
/// 标签只有增益、没有峰值，所以这里不做峰值限幅，只做参考响度偏移。
double replayGainForTag(
  double tagGainDb, {
  double referenceLufs = replayGainDefaultReference,
}) {
  if (!tagGainDb.isFinite || tagGainDb == 0) {
    return 0;
  }
  return (tagGainDb + (referenceLufs - replayGainDefaultReference))
      .clamp(-replayGainLimitDb, replayGainLimitDb)
      .toDouble();
}

/// 存档里读回的参考响度：只接受已知的几档，其余（老存档 / 脏数据）回落默认
double parseReplayGainReference(double? stored) {
  if (stored == null) {
    return replayGainDefaultReference;
  }
  return replayGainReferences.contains(stored)
      ? stored
      : replayGainDefaultReference;
}
