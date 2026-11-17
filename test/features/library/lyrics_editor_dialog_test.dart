import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/widgets/lyrics_editor_dialog.dart';

const String _lrc = '[ti:夜航]\n[00:10.00]第一行\n[00:20.00]第二行\n';

/// 子窗 `Navigator.pop` 带回来的值（取消为 null）
String? _result;
bool _closed = false;

/// 打开子窗：走 `showDialog` 而不是直接塞进 `Scaffold`，
/// 这样 pop 的返回值能真的被接住（测「取消」与「完成」都靠它）
Future<void> _open(
  WidgetTester tester, {
  String lyrics = _lrc,
  String source = 'sidecar',
  bool embedTarget = false,
  Future<String> Function(String text, int deltaMs)? onShiftLyrics,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              _result = await showDialog<String>(
                context: context,
                builder: (BuildContext _) => LyricsEditorDialog(
                  lyricsText: lyrics,
                  lyricsSource: source,
                  embedTarget: embedTarget,
                  onShiftLyrics:
                      onShiftLyrics ?? (String text, int deltaMs) async => text,
                ),
              );
              _closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _bigWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 来源小标签的 tooltip：说明保存会落到哪儿
String? _chipMessage(WidgetTester tester) {
  return tester
      .widget<Tooltip>(
        find.ancestor(of: find.text('来自 .lrc'), matching: find.byType(Tooltip)),
      )
      .message;
}

void main() {
  setUp(() {
    _result = null;
    _closed = false;
  });

  testWidgets('来源标签说明旁载歌词会写成 .lrc', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);
    expect(_chipMessage(tester), '保存时写入同名 .lrc');
  });

  testWidgets('选了内嵌时，来源标签说明写进音频标签', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester, embedTarget: true);
    expect(_chipMessage(tester), '保存时写入音频标签');
  });

  testWidgets('预填原文，标题与来源都在', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);

    expect(find.text('编辑歌词'), findsOneWidget);
    expect(find.text('来自 .lrc'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('lyrics-editor')),
          )
          .controller!
          .text,
      _lrc,
    );
  });

  testWidgets('整体提前 1 秒 200 毫秒：按 -1200ms 平移并替换文本', (WidgetTester tester) async {
    _bigWindow(tester);

    int? delta;
    String? received;
    await _open(
      tester,
      onShiftLyrics: (String text, int deltaMs) async {
        delta = deltaMs;
        received = text;
        return text.replaceAll('[00:10.00]', '[00:08.80]');
      },
    );

    await tester.enterText(find.widgetWithText(TextField, '秒'), '1');
    await tester.enterText(find.widgetWithText(TextField, '毫秒'), '200');
    await tester.tap(find.widgetWithText(OutlinedButton, '应用到时间轴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(delta, -1200, reason: '默认「提前」= 时间戳减小');
    expect(received, _lrc, reason: '要把当前编辑器里的全文交出去');
    final TextField editor = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('lyrics-editor')),
    );
    expect(editor.controller!.text, contains('[00:08.80]'));

    // 平移成功后输入框清空，避免连点两次却以为是同一次
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '秒'))
          .controller!
          .text,
      '',
    );
  });

  testWidgets('切到「延后」时增量是正数', (WidgetTester tester) async {
    _bigWindow(tester);

    int? delta;
    await _open(
      tester,
      onShiftLyrics: (String text, int deltaMs) async {
        delta = deltaMs;
        return text;
      },
    );

    await tester.tap(find.text('延后'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '毫秒'), '250');
    await tester.tap(find.widgetWithText(OutlinedButton, '应用到时间轴'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(delta, 250);
    // 文本没变（stub 原样返回）：要提示「没有可平移的时间戳」，别让人以为点坏了
    expect(find.textContaining('没有可平移的时间戳'), findsOneWidget);
  });

  testWidgets('没填偏移就点应用：提示先填数字', (WidgetTester tester) async {
    _bigWindow(tester);

    int calls = 0;
    await _open(
      tester,
      onShiftLyrics: (String text, int deltaMs) async {
        calls += 1;
        return text;
      },
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '应用到时间轴'));
    await tester.pump();

    expect(calls, 0);
    expect(find.textContaining('先填要快进'), findsOneWidget);
  });

  testWidgets('点完成把新文本带回去', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);

    await tester.enterText(
      find.byKey(const ValueKey<String>('lyrics-editor')),
      '[00:10.00]改过的\n',
    );
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_closed, isTrue);
    expect(_result, '[00:10.00]改过的\n');
    expect(find.byType(LyricsEditorDialog), findsNothing);
  });

  testWidgets('点取消返回 null，等于没改', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);

    await tester.enterText(
      find.byKey(const ValueKey<String>('lyrics-editor')),
      '[00:10.00]不该带回去\n',
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_closed, isTrue);
    expect(_result, isNull);
  });
}
