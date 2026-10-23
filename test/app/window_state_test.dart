import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/window_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('没有存档时使用默认尺寸', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final WindowSnapshot snapshot = await const PrefsWindowStateStore().load();

    expect(snapshot.size, const Size(1180, 760));
    expect(snapshot.position, isNull, reason: '没有位置记录时应居中');
    expect(snapshot.maximized, isFalse);
  });

  test('保存后恢复尺寸、位置与最大化状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsWindowStateStore store = PrefsWindowStateStore();

    await store.save(
      const WindowSnapshot(
        size: Size(1440, 900),
        position: Offset(120, 80),
        maximized: true,
      ),
    );

    final WindowSnapshot snapshot = await store.load();
    expect(snapshot.size, const Size(1440, 900));
    expect(snapshot.position, const Offset(120, 80));
    expect(snapshot.maximized, isTrue);
  });

  test('位置清空后不再残留', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsWindowStateStore store = PrefsWindowStateStore();

    await store.save(
      const WindowSnapshot(size: Size(1200, 800), position: Offset(10, 20)),
    );
    await store.save(const WindowSnapshot());

    final WindowSnapshot snapshot = await store.load();
    expect(snapshot.position, isNull);
  });

  test('记忆的位置只要还有足够可见区域就沿用', () {
    const Rect primary = Rect.fromLTWH(0, 0, 1920, 1080);
    const Rect secondary = Rect.fromLTWH(1920, 0, 1920, 1080);

    expect(
      isWindowVisibleOn(
        position: const Offset(2000, 100),
        size: const Size(1180, 760),
        displays: <Rect>[primary, secondary],
      ),
      isTrue,
      reason: '副屏上的窗口应保留',
    );
    expect(
      isWindowVisibleOn(
        position: const Offset(5000, 100),
        size: const Size(1180, 760),
        displays: <Rect>[primary, secondary],
      ),
      isFalse,
      reason: '显示器拔掉后旧坐标应视为不可见',
    );
    expect(
      isWindowVisibleOn(
        position: const Offset(-1100, 300),
        size: const Size(1180, 760),
        displays: <Rect>[primary],
      ),
      isFalse,
      reason: '只露出很窄一条不足以拖回窗口',
    );
  });

  test('异常小尺寸被抬到最低可用尺寸', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${PrefsWindowStateStore.widthKey}': 200.0,
      'flutter.${PrefsWindowStateStore.heightKey}': 100.0,
    });

    final WindowSnapshot snapshot = await const PrefsWindowStateStore().load();
    expect(snapshot.size.width, PrefsWindowStateStore.minWidth);
    expect(snapshot.size.height, PrefsWindowStateStore.minHeight);
  });
}
