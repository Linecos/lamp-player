import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/common.dart';

// 纯 Dart 测试：不初始化 Rust，也不依赖任何原生库，
// 保证没有 Rust 工具链的贡献者也能 `flutter test` 通过（见 docs/ARCHITECTURE.md 第 7 节）。
void main() {
  group('formatDuration', () {
    test('零与负值都归零', () {
      expect(formatDuration(0), '00:00');
      expect(formatDuration(-1), '00:00');
      expect(formatDuration(-3600.5), '00:00');
    });

    test('四舍五入到整秒，不截断', () {
      expect(formatDuration(1), '00:01');
      expect(formatDuration(59.4), '00:59');
      expect(formatDuration(59.5), '01:00');
      expect(formatDuration(237.4), '03:57');
    });

    test('满 1 小时切换成 h:mm:ss，小时不补零', () {
      expect(formatDuration(3599), '59:59');
      expect(formatDuration(3600), '1:00:00');
      expect(formatDuration(3837), '1:03:57');
      expect(formatDuration(360000), '100:00:00');
    });

    test('NaN 与无穷大按 0 处理', () {
      expect(formatDuration(double.nan), '00:00');
      expect(formatDuration(double.infinity), '00:00');
      expect(formatDuration(double.negativeInfinity), '00:00');
    });
  });

  group('formatDurationCompact', () {
    test('始终省略小时，超过 1 小时按总分钟数显示', () {
      expect(formatDurationCompact(0), '00:00');
      expect(formatDurationCompact(59), '00:59');
      expect(formatDurationCompact(3600), '60:00');
      expect(formatDurationCompact(3837), '63:57');
    });

    test('非法输入按 0 处理', () {
      expect(formatDurationCompact(-3), '00:00');
      expect(formatDurationCompact(double.nan), '00:00');
    });
  });

  group('formatFileSize', () {
    test('不足 1 KB 用整数 B', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(-2048), '0 B');
      expect(formatFileSize(1), '1 B');
      expect(formatFileSize(1023), '1023 B');
    });

    test('1024 进制，且去掉末尾多余的 0', () {
      expect(formatFileSize(1024), '1 KB');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(1048576), '1 MB');
      expect(formatFileSize(1073741824), '1 GB');
    });

    test('保留两位小数', () {
      // 1523712 / 1048576 = 1.453125
      expect(formatFileSize(1523712), '1.45 MB');
    });

    test('极大值落到 PB 而不越界', () {
      expect(formatFileSize(1125899906842624), '1 PB');
    });
  });
}
