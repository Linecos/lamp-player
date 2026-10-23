import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/audio/volume_curve.dart';

void main() {
  test('满音量保持满幅，零音量完全静音', () {
    expect(volumeToAmplitude(1), 1);
    expect(volumeToAmplitude(0), 0);
  });

  test('低音量段被显著压低', () {
    expect(volumeToAmplitude(0.5), closeTo(0.125, 0.0001));
    expect(volumeToAmplitude(0.25), closeTo(0.015625, 0.0001));
    expect(volumeToAmplitude(0.1), closeTo(0.001, 0.0001));
  });

  test('曲线单调递增，越界值被夹到 0~1', () {
    double previous = -1;
    for (int step = 0; step <= 20; step += 1) {
      final double amplitude = volumeToAmplitude(step / 20);
      expect(amplitude, greaterThanOrEqualTo(previous));
      previous = amplitude;
    }
    expect(volumeToAmplitude(-1), 0);
    expect(volumeToAmplitude(2), 1);
  });
}
