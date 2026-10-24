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
