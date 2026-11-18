import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app_version.dart';
import 'package:lamp_player/src/common/external_link.dart';
import 'package:lamp_player/src/features/settings/about_dialog.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
import 'package:lamp_player/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home) => MaterialApp(
  theme: AppTheme.light(AppTheme.defaultSeed),
  home: Scaffold(body: home),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('设置页点「关于」打开弹窗：图标、名字、版本、三个技术栈都在', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(const SettingsView()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lamp Player'));
    await tester.pumpAndSettle();

    expect(find.byType(AppAboutDialog), findsOneWidget);
    // 图标：asset 图要真的能加载（找不到时 pumpAndSettle 会抛）
    expect(
      find.descendant(
        of: find.byType(AppAboutDialog),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(find.text('Lamp Player 版本'), findsOneWidget);
    expect(find.text('v$appVersion'), findsOneWidget);
    for (final String tech in AppAboutDialog.techStack) {
      expect(find.text(tech), findsOneWidget, reason: tech);
    }
    for (final String label in <String>['GitHub', '更新日志', '开源许可', '问题反馈']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('由 Linecos 开发'), findsOneWidget);
    expect(find.text('© 2026 Linecos  开源许可'), findsOneWidget);

    // 右上角叉关掉
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AppAboutDialog), findsNothing);
  });

  testWidgets('版本号旁的复制按钮把版本写进剪贴板', (WidgetTester tester) async {
    final List<String> copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (BuildContext context) => Center(
            child: AppAboutDialog(openUrl: (String url) async => true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('复制版本号'));
    await tester.pumpAndSettle();

    expect(copied, <String>['v$appVersion']);
    expect(find.byTooltip('已复制'), findsOneWidget, reason: '复制后图标变勾');
  });

  testWidgets('四个链接各自交给 openUrl，且是正确地址', (WidgetTester tester) async {
    final List<String> opened = <String>[];
    tester.view.physicalSize = const Size(760, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => showAppAboutDialog(
                context,
                openUrl: (String url) async {
                  opened.add(url);
                  return true;
                },
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    for (final String label in <String>['GitHub', '更新日志', '开源许可', '问题反馈']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    expect(opened, <String>[
      AppAboutDialog.githubUrl,
      AppAboutDialog.changelogUrl,
      AppAboutDialog.licenseUrl,
      AppAboutDialog.issuesUrl,
    ]);
    for (final String url in opened) {
      expect(Uri.parse(url).isScheme('https'), isTrue, reason: url);
    }
  });

  test('外部链接只接受 http(s)，别的协议直接拒绝', () async {
    // 拒绝发生在拉起浏览器之前，所以这条用例不会真的开窗口
    expect(await openExternalUrl('file:///C:/Windows'), isFalse);
    expect(await openExternalUrl('javascript:alert(1)'), isFalse);
  });
}
