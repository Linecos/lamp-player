import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/cover_editor_dialog.dart';

/// 1×1 透明 PNG：只要能被 `Image.file` 认出来就行，不关心画面内容
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<File> _writePng(String name) async {
  final Directory dir = await Directory.systemTemp.createTemp(
    'lamp_cover_dialog',
  );
  final File file = File('${dir.path}/$name');
  await file.writeAsBytes(base64Decode(_onePixelPng));
  return file;
}

Widget _host(CoverEditorDialog dialog) {
  return MaterialApp(
    home: Scaffold(body: Center(child: dialog)),
  );
}

CoverEditorDialog _dialog({
  String? coverPath,
  bool circular = false,
  bool hasCustomCover = false,
  Future<String?> Function()? onPick,
  Future<String?> Function()? onReset,
}) {
  return CoverEditorDialog(
    title: '林间电台',
    kindLabel: '艺术家',
    coverPath: coverPath,
    circular: circular,
    hasCustomCover: hasCustomCover,
    onPick: onPick ?? () async => null,
    onReset: onReset ?? () async => null,
  );
}

void main() {
  testWidgets('预览取可用空间的短边，宽高相等', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 真实文件 IO 必须走 runAsync：widget 测试跑在 fake async 里，
    // 直接 await 一个真正的 Future 会永远挂住（表现为 did not complete）
    final File file = (await tester.runAsync(() => _writePng('a.png')))!;
    addTearDown(() => file.parent.deleteSync(recursive: true));

    await tester.pumpWidget(_host(_dialog(coverPath: file.path)));
    await tester.pump();

    final Size size = tester.getSize(find.byType(Image).first);
    expect(
      size.width,
      closeTo(size.height, 0.5),
      reason: '预览必须是正方形：宽 ${size.width} 高 ${size.height}',
    );
    expect(size.width, greaterThan(120), reason: '大窗口下预览不该被压得很小');
  });

  testWidgets('窗口变小后对话框跟着缩，且不溢出', (WidgetTester tester) async {
    // 小于设计尺寸的一半：最容易把按钮和预览挤爆
    tester.view.physicalSize = const Size(520, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final File file = (await tester.runAsync(() => _writePng('b.png')))!;
    addTearDown(() => file.parent.deleteSync(recursive: true));

    await tester.pumpWidget(_host(_dialog(coverPath: file.path)));
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '缩到 520×400 也不该溢出');

    final Size size = tester.getSize(find.byType(Image).first);
    expect(size.width, closeTo(size.height, 0.5));

    final Rect dialog = tester.getRect(find.byType(Dialog));
    expect(dialog.width, lessThanOrEqualTo(520));
    expect(dialog.height, lessThanOrEqualTo(400));
  });

  testWidgets('没有自定义封面时「恢复默认」不可点', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_dialog()));
    await tester.pump();

    final OutlinedButton button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '恢复默认'),
    );
    expect(button.onPressed, isNull, reason: '没有可恢复的东西，禁用比点了没反应清楚');
  });

  testWidgets('有自定义封面时「恢复默认」可点，点完预览回到占位', (WidgetTester tester) async {
    final File file = (await tester.runAsync(() => _writePng('c.png')))!;
    addTearDown(() => file.parent.deleteSync(recursive: true));

    bool resetCalled = false;
    await tester.pumpWidget(
      _host(
        _dialog(
          coverPath: file.path,
          hasCustomCover: true,
          onReset: () async {
            resetCalled = true;
            return null; // 没有自动封面：预览应回到占位
          },
        ),
      ),
    );
    await tester.pump();

    final OutlinedButton button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '恢复默认'),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.widgetWithText(OutlinedButton, '恢复默认'));
    // 不用 pumpAndSettle：Image.file 在测试环境里会一直挂着解码，
    // 导致 settle 永远等不完
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(resetCalled, isTrue);
    // 传进来的 coverPath 是自定义那张，撤掉后应回到「没有封面」的占位
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('点「更换封面」会走到选图回调', (WidgetTester tester) async {
    // 这里只验证「点了会去选图」：真的让预览换成另一张图会触发 Image.file
    // 的真实解码，在 widget 测试的 fake async 里永远 pending，测试会挂死。
    // 预览更新那一段靠上面的「恢复默认」用例覆盖（同样是换 _path）。
    int picked = 0;
    await tester.pumpWidget(
      _host(
        _dialog(
          onPick: () async {
            picked += 1;
            return null; // 模拟用户在系统对话框里点了取消
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, '更换封面…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(picked, 1);
  });
}
