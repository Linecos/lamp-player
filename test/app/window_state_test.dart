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
    expect(snapshot.maximized, isFalse);
  });

  test('保存后恢复尺寸与最大化状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PrefsWindowStateStore store = PrefsWindowStateStore();

    await store.save(
      const WindowSnapshot(size: Size(1440, 900), maximized: true),
    );

    final WindowSnapshot snapshot = await store.load();
    expect(snapshot.size, const Size(1440, 900));
    expect(snapshot.maximized, isTrue);
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
