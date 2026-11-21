import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

void main() {
  testWidgets('内置文案走中文：右键菜单是「复制」而不是 Copy，字阶几何切到 dense', (
    WidgetTester tester,
  ) async {
    MaterialLocalizations? loc;
    ScriptCategory? category;
    String? copyLabel;
    double? spacing;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        locale: appLocale,
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Builder(
          builder: (BuildContext context) {
            loc = MaterialLocalizations.of(context);
            category = loc!.scriptCategory;
            copyLabel = loc!.copyButtonLabel;
            spacing = Theme.of(context).textTheme.bodyMedium?.letterSpacing;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(loc, isNotNull);
    expect(copyLabel, '复制', reason: '默认的 DefaultMaterialLocalizations 是英文');
    expect(
      category,
      ScriptCategory.dense,
      reason: '中文要用表意基线那套几何，而不是 englishLike',
    );
    expect(
      spacing,
      0,
      reason: '字距归零要能穿透 Theme 的 localized 合并，不能被 englishLike 的 0.25 盖回去',
    );
  });

  testWidgets('中文长段文字不再每个字多推半像素', (WidgetTester tester) async {
    List<TextStyle?> styles = const <TextStyle?>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        locale: appLocale,
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Builder(
          builder: (BuildContext context) {
            final TextTheme text = Theme.of(context).textTheme;
            styles = <TextStyle?>[
              text.bodyLarge,
              text.bodyMedium,
              text.bodySmall,
              text.labelMedium,
              text.labelSmall,
              text.titleMedium,
            ];
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    for (final TextStyle? style in styles) {
      expect(style?.letterSpacing, 0, reason: '${style?.fontSize}px 这档还在推字距');
    }
  });
}
