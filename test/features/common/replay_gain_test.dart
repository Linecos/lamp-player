import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/audio/replay_gain.dart';

void main() {
  group('replayGainForLoudness', () {
    test('增益 = 参考响度 − 实测响度', () {
      expect(
        replayGainForLoudness(loudnessLufs: -25.5, peak: 0),
        closeTo(7.5, 1e-9),
      );
      expect(
        replayGainForLoudness(loudnessLufs: -25.5, peak: 0, referenceLufs: -23),
        closeTo(2.5, 1e-9),
      );
      expect(
        replayGainForLoudness(loudnessLufs: -25.5, peak: 0, referenceLufs: -14),
        closeTo(11.5, 1e-9),
      );
      // 本身就很响的曲目会被压下来
      expect(
        replayGainForLoudness(loudnessLufs: -3.7, peak: 0),
        closeTo(-14.3, 0.01),
      );
    });

    test('峰值把增益压到 0 dBFS 为止', () {
      // 峰值 0.9 ≈ -0.92 dBFS：-14 LUFS 目标原本会给 +16 dB，压到 +0.92
      expect(
        replayGainForLoudness(loudnessLufs: -30, peak: 0.9, referenceLufs: -14),
        closeTo(0.915, 0.01),
      );
      // 真峰值更低（0.6 ≈ -4.44 dBFS）：限得更狠
      expect(
        replayGainForLoudness(loudnessLufs: -30, peak: 0.6, referenceLufs: -14),
        closeTo(4.437, 0.01),
      );
      // 目标本身就在峰值允许的范围内：峰值不参与（0.05 ≈ -26 dBFS）
      expect(
        replayGainForLoudness(loudnessLufs: -25.5, peak: 0.05),
        closeTo(7.5, 1e-9),
      );
    });

    test('响度未知按 0，增益夹在 ±24 dB', () {
      expect(replayGainForLoudness(loudnessLufs: 0, peak: 0), 0);
      expect(
        replayGainForLoudness(loudnessLufs: -50, peak: 0, referenceLufs: -14),
        replayGainLimitDb,
      );
      expect(
        replayGainForLoudness(loudnessLufs: -2, peak: 0, referenceLufs: -18),
        -16.0,
      );
      expect(
        replayGainForLoudness(loudnessLufs: 30, peak: 0, referenceLufs: -18),
        -replayGainLimitDb,
      );
    });
  });

  group('replayGainForTag', () {
    test('标签增益（-18 口径）按参考响度偏移，不做峰值限幅', () {
      expect(replayGainForTag(-7.5), closeTo(-7.5, 1e-9));
      expect(replayGainForTag(-7.5, referenceLufs: -23), closeTo(-12.5, 1e-9));
      expect(replayGainForTag(-7.5, referenceLufs: -14), closeTo(-3.5, 1e-9));
      expect(replayGainForTag(20, referenceLufs: -14), replayGainLimitDb);
    });

    test('没有标签（0 / NaN）按 0 处理', () {
      expect(replayGainForTag(0), 0);
      expect(replayGainForTag(double.nan), 0);
    });
  });

  test('parseReplayGainReference 只认已知档位', () {
    expect(parseReplayGainReference(null), replayGainDefaultReference);
    expect(parseReplayGainReference(-14), -14);
    expect(parseReplayGainReference(-23), -23);
    expect(parseReplayGainReference(-7), replayGainDefaultReference);
  });
}
