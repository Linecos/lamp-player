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
  testWidgets('大窗口下封面是正方形、尺寸封顶且贴左上角', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
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
    // 窗口放大到 1200×900 也不再跟着涨：封面是缩略图，不是整面墙
    expect(
      size.width,
      closeTo(300, 0.5),
      reason: '大窗口下封面应停在上限 300，实际 ${size.width}',
    );

    // 位置：贴着对话框左上（留 28 的边），而不是像以前那样垂直居中。
    // 量的是内容框（外层 Column），不是 Dialog 自己——Dialog 的矩形含全屏留白
    final Rect content = tester.getRect(find.byType(Column).first);
    final Rect cover = tester.getRect(find.byType(Image).first);
    expect(content.width, closeTo(880, 1), reason: '窗口放大到 880 宽');
    expect(cover.left - content.left, closeTo(28, 0.5), reason: '封面应贴左边');
    expect(cover.top - content.top, closeTo(28, 0.5), reason: '封面应贴顶边');

    // 选项在封面右侧：两个按钮的左边都落在封面右边界之外
    for (final Finder button in <Finder>[
      find.widgetWithText(FilledButton, '更换封面…'),
      find.widgetWithText(OutlinedButton, '恢复默认'),
    ]) {
      expect(
        tester.getRect(button).left,
        greaterThan(cover.right),
        reason: '选项应排在封面右边，不压在图上',
      );
    }

    // 页脚：「关闭」贴内容框右下角（右 28、下 16），提示语在它上方居中
    final Rect close = tester.getRect(find.widgetWithText(TextButton, '关闭'));
    expect(
      content.right - close.right,
      closeTo(28, 0.5),
      reason: '关闭要落在右下角，不该停在选项列里',
    );
    expect(content.bottom - close.bottom, closeTo(16, 0.5));

    final Finder hint = find.text('建议用正方形图片；过大的图会自动缩到 1024 长边。');
    expect(
      tester.widget<Text>(hint).textAlign,
      TextAlign.center,
      reason: '提示语整段居中',
    );
    expect(tester.getRect(hint).bottom, lessThanOrEqualTo(close.top));
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
