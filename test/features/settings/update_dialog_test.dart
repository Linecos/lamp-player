import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/update_check.dart';
import 'package:lamp_player/src/common/scroll/smooth_scroll.dart';
import 'package:lamp_player/src/features/settings/update_dialog.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

const UpdateRelease _release = UpdateRelease(
  version: '0.2.0',
  notes: '### 修复\n- 修某处\n- 修另一处',
  downloadUrl: 'https://example.com/a.zip',
);

Widget _harness(OpenExternalUrlSpy spy) {
  return MaterialApp(
    theme: AppTheme.light(AppTheme.defaultSeed),
    home: Builder(
      builder: (BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () =>
                showUpdateAvailableDialog(context, _release, openUrl: spy.call),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
}

/// 伪浏览器：记下被打开的链接，不真去拉 ShellExecute
class OpenExternalUrlSpy {
  final List<String> opened = <String>[];

  Future<bool> call(String url) async {
    opened.add(url);
    return true;
  }
}

void main() {
  testWidgets('弹窗展示版本、说明与下载按钮，点下载会打开链接', (WidgetTester tester) async {
    final OpenExternalUrlSpy spy = OpenExternalUrlSpy();
    await tester.pumpWidget(_harness(spy));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v0.2.0'), findsOneWidget);
    expect(find.textContaining('当前版本'), findsOneWidget);
    expect(find.textContaining('修某处', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('###', findRichText: true),
      findsNothing,
      reason: '发布说明按 Markdown 渲染，不该把井号露出来',
    );
    expect(find.text('修复', findRichText: true), findsOneWidget);
    // 发布说明可能很长：滚轮要走平滑滚动，不能是裸 SingleChildScrollView
    expect(find.byType(SmoothSingleChildScrollView), findsOneWidget);

    await tester.tap(find.text('前往下载'));
    await tester.pumpAndSettle();

    expect(spy.opened, <String>['https://example.com/a.zip']);
    expect(find.text('发现新版本 v0.2.0'), findsNothing, reason: '点完就关掉弹窗');
  });

  testWidgets('稍后再说只关弹窗，不打开链接', (WidgetTester tester) async {
    final OpenExternalUrlSpy spy = OpenExternalUrlSpy();
    await tester.pumpWidget(_harness(spy));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();

    expect(spy.opened, isEmpty);
    expect(find.text('发现新版本 v0.2.0'), findsNothing);
  });
}
