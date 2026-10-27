/// 均衡器的 10 个频段（Hz），与 Rust 端 `EQ_CENTERS` 一一对应。
const List<int> equalizerBandCenters = <int>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// 增益上下限（dB），与 Rust 端 `EQ_MAX_GAIN` 一致。
const double equalizerMaxGain = 15;

/// 频段短标签（低频 → 高频）
const List<String> equalizerBandLabels = <String>[
  '31',
  '62',
  '125',
  '250',
  '500',
  '1k',
  '2k',
  '4k',
  '8k',
  '16k',
];

/// 补齐 / 裁剪到 10 段并夹到 ±15 dB。
///
/// 老会话里可能没存过均衡器（空列表），也可能某天段数变了——统一在这里兜底，
/// 免得把长度不对的数组发给 Rust（那边会直接报错）。
List<double> normalizeEqGains(List<double> gains) {
  return List<double>.generate(equalizerBandLabels.length, (int index) {
    final double value = index < gains.length ? gains[index] : 0;
    if (!value.isFinite) {
      return 0;
    }
    return value.clamp(-equalizerMaxGain, equalizerMaxGain);
  }, growable: false);
}

/// 是否所有频段都是 0 dB
bool isEqFlat(List<double> gains) =>
    normalizeEqGains(gains).every((double gain) => gain.abs() < 0.05);

/// 一个内置预设：名称与 10 段增益（dB，31Hz→16kHz）。
class EqualizerPreset {
  const EqualizerPreset(this.name, this.gains);

  final String name;
  final List<double> gains;
}

/// 内置预设。曲线偏保守：都在 ±7 dB 以内，避免一开就削波。
const List<EqualizerPreset> equalizerPresets = <EqualizerPreset>[
  EqualizerPreset('流行', <double>[-1, 0, 2, 3, 2, 0, -1, -2, -1, 0]),
  EqualizerPreset('摇滚', <double>[4, 3, 1.5, -1, -2, 0, 2, 3.5, 4, 3.5]),
  EqualizerPreset('古典', <double>[2, 1.5, 0.5, 0, 0, 0, 0.5, 1.5, 2.5, 3]),
  EqualizerPreset('人声', <double>[-3, -2, -1, 2, 4, 4.5, 3, 1, -1, -2]),
  EqualizerPreset('重低音', <double>[7, 6, 4.5, 2.5, 0, -1, -1.5, -1, 0, 0.5]),
];

/// 当前增益是否正好等于某个预设；不是则返回 -1（自定义）
int matchedPresetIndex(List<double> gains) {
  final List<double> current = normalizeEqGains(gains);
  for (int index = 0; index < equalizerPresets.length; index += 1) {
    final List<double> preset = equalizerPresets[index].gains;
    bool same = true;
    for (int band = 0; band < current.length; band += 1) {
      if ((current[band] - preset[band]).abs() > 0.05) {
        same = false;
        break;
      }
    }
    if (same) {
      return index;
    }
  }
  return -1;
}
