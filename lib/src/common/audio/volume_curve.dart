import 'dart:math' as math;

/// 界面音量到引擎振幅的映射。
///
/// BASS 的 `BASS_ATTRIB_VOL` 是线性振幅，而人耳对响度的感知接近对数：
/// 把滑块值直接当振幅用，拖到 30% 时仍有接近三分之一的响度，低音量段
/// 几乎没法细调。这里用三次曲线，让前半段充分压低、后半段再接近满幅：
///
/// - 100% → 1.0（0 dB）
/// - 50%  → 0.125（约 -18 dB）
/// - 25%  → 0.016（约 -36 dB）
/// - 10%  → 0.001（约 -60 dB）
///
/// 注意：滑块值是按新语义（感知音量）存的，**老存档不能直接读**——
/// 老版本把滑块值当振幅用，同样的 0.5 在新曲线下会低 12 dB。
/// 迁移见 [`amplitudeToVolume`] 与 `PrefsSessionStore.volumeCurveVersion`。
double volumeToAmplitude(double volume) {
  final double value = volume.clamp(0.0, 1.0);
  return value * value * value;
}

/// [`volumeToAmplitude`] 的反函数：振幅 → 等响度的滑块值。
///
/// 用于音量曲线升级时迁移老存档（老存档里的值其实是振幅），
/// 迁移后滑块位置会往右移，但听感与升级前一致。
double amplitudeToVolume(double amplitude) {
  final double value = amplitude.clamp(0.0, 1.0);
  return math.pow(value, 1 / 3).toDouble();
}
