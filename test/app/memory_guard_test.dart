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

  test('前台修剪完要再涨一台阶才允许动第二次（迟滞）', () {
    // 第一次：还没有基线，超阈值就剪
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 235 * mb,
        visible: true,
        baselineBytes: -1,
      ),
      isTrue,
    );
    // 稳态：只涨了 35MB，还没到 40 的台阶
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 235 * mb,
        visible: true,
        baselineBytes: 200 * mb,
      ),
      isFalse,
    );
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 239 * mb,
        visible: true,
        baselineBytes: 200 * mb,
      ),
      isFalse,
      reason: '差 1MB 也不动，否则门槛就形同虚设',
    );
    // 涨满台阶：该剪了
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 240 * mb,
        visible: true,
        baselineBytes: 200 * mb,
      ),
      isTrue,
    );
  });

  test('不可见时不受迟滞限制，超了就剪', () {
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 155 * mb,
        visible: false,
        baselineBytes: 200 * mb,
      ),
      isTrue,
      reason: '没人看画面，多剪一次只有好处；基线比当前还高时更要剪',
    );
  });

  test('没超阈值时什么都不做', () {
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 229 * mb,
        visible: true,
        baselineBytes: -1,
      ),
      isFalse,
    );
    expect(
      MemoryGuard.shouldTrim(
        rssBytes: 149 * mb,
        visible: false,
        baselineBytes: -1,
      ),
      isFalse,
    );
  });
}
