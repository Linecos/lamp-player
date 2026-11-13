import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/memory_guard.dart';

void main() {
  const int mb = 1 << 20;

  test('前台要超过 230MB 才修剪，不可见时 150MB 就动手', () {
    expect(MemoryGuard.overLimit(229 * mb, visible: true), isFalse);
    expect(MemoryGuard.overLimit(230 * mb, visible: true), isTrue);

    expect(MemoryGuard.overLimit(149 * mb, visible: false), isFalse);
    expect(MemoryGuard.overLimit(150 * mb, visible: false), isTrue);
  });

  test('不可见的阈值必须比前台低，否则最小化时反而更保守', () {
    expect(
      MemoryGuard.hiddenLimitBytes,
      lessThan(MemoryGuard.visibleLimitBytes),
    );
  });
}
