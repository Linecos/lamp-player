import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/common.dart';

// 组件测试：只验证渲染与回调，不触碰 Rust 接口。
Future<void> _pumpInScaffold(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('EmptyState', () {
    testWidgets('渲染图标、标题、说明与行动按钮', (WidgetTester tester) async {
      await _pumpInScaffold(
        tester,
        EmptyState(
          icon: Icons.library_music_outlined,
          title: '曲库还是空的',
          message: '在设置里添加一个音乐目录。',
          action: FilledButton(onPressed: () {}, child: const Text('去设置')),
        ),
      );

      expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
      expect(find.text('曲库还是空的'), findsOneWidget);
      expect(find.text('在设置里添加一个音乐目录。'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
    });

    testWidgets('省略说明与按钮时只渲染图标和标题', (WidgetTester tester) async {
      await _pumpInScaffold(
        tester,
        const EmptyState(icon: Icons.search_off, title: '没有匹配的曲目'),
      );

      expect(find.byIcon(Icons.search_off), findsOneWidget);
      expect(find.text('没有匹配的曲目'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('行动按钮可点击', (WidgetTester tester) async {
      int taps = 0;
      await _pumpInScaffold(
        tester,
        EmptyState(
          icon: Icons.folder_open,
          title: '还没有目录',
          action: FilledButton(
            onPressed: () => taps += 1,
            child: const Text('添加目录'),
          ),
        ),
      );

      await tester.tap(find.text('添加目录'));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('LoadingState', () {
    testWidgets('渲染进度指示器与文案', (WidgetTester tester) async {
      await _pumpInScaffold(tester, const LoadingState(message: '正在扫描…'));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在扫描…'), findsOneWidget);
    });

    testWidgets('没有文案时只渲染进度指示器', (WidgetTester tester) async {
      await _pumpInScaffold(tester, const LoadingState());

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('ErrorRetry', () {
    testWidgets('渲染标题与去掉前缀的错误文本，点击触发回调', (WidgetTester tester) async {
      int retries = 0;
      await _pumpInScaffold(
        tester,
        ErrorRetry(
          title: '扫描失败',
          error: Exception('目录不存在'),
          onRetry: () => retries += 1,
        ),
      );

      expect(find.text('扫描失败'), findsOneWidget);
      expect(find.text('目录不存在'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();

      expect(retries, 1);
    });

    test('describe 去掉 Exception / Error 前缀', () {
      expect(ErrorRetry.describe(Exception('曲库未初始化')), '曲库未初始化');
      // StateError 的 toString 自带 'Bad state: ' 前缀，不属于要剥掉的两类，原样保留
      expect(ErrorRetry.describe(StateError('状态异常')), 'Bad state: 状态异常');
      expect(ErrorRetry.describe('普通字符串'), '普通字符串');
    });

    test('describe 对空错误给出兜底文案', () {
      expect(ErrorRetry.describe(Exception()), '未知错误');
      expect(ErrorRetry.describe(''), '未知错误');
    });
  });
}
