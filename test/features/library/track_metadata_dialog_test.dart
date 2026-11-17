import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/track_metadata_dialog.dart';
import 'package:lamp_player/src/rust/api/metadata.dart';

TrackTags _tags({
  String title = '夜航',
  String artist = '林间电台',
  String album = '深夜频道',
  String albumArtist = '',
  String year = '2003',
  String trackNo = '3',
  String discNo = '',
  String genre = 'Ambient',
}) {
  return TrackTags(
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    year: year,
    trackNo: trackNo,
    discNo: discNo,
    genre: genre,
  );
}

const String _lrc = '[ti:夜航]\n[00:10.00]第一行\n[00:20.00]第二行\n';

/// 用 `showDialog` 打开（跟真机一致）：直接塞进 `Scaffold` 的话保存后
/// `Navigator.pop` 会把唯一的路由弹掉，测不出「弹窗关掉了」
Future<void> _open(
  WidgetTester tester, {
  String lyrics = _lrc,
  String source = 'sidecar',
  String? coverPath,
  TrackTags? tags,
  Future<String> Function(String text, int deltaMs)? onShiftLyrics,
  Future<void> Function(TrackTags tags, String lyrics)? onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (BuildContext _) => TrackMetadataDialog(
                coverPath: coverPath,
                tags: tags ?? _tags(),
                lyricsText: lyrics,
                lyricsSource: source,
                onShiftLyrics:
                    onShiftLyrics ?? (String text, int deltaMs) async => text,
                onSave: onSave ?? (TrackTags tags, String lyrics) async {},
              ),
            ),
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

void main() {
  testWidgets('字段按初始标签预填，歌词与来源都在', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _open(tester, lyrics: _lrc);

    for (final String label in <String>[
      '标题',
      '艺术家',
      '专辑',
      '专辑艺术家',
      '年份',
      '音轨号',
      '碟号',
      '流派',
    ]) {
      expect(
        find.widgetWithText(TextField, label),
        findsOneWidget,
        reason: '缺少字段：$label',
      );
    }
    expect(find.text('夜航'), findsWidgets, reason: '标题要预填成标签里的值');
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

  testWidgets('封面在右上角，窗口做大到 980×660', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _open(tester);

    // 外层 Column 才是内容框（Dialog 的矩形含全屏留白）
    final Rect content = tester.getRect(find.byType(Column).first);
    expect(content.width, closeTo(980, 1));
    expect(content.height, closeTo(660, 1));

    final Rect cover = tester.getRect(find.byType(AlbumCover));
    expect(cover.width, closeTo(168, 0.5));
    expect(
      content.right - cover.right,
      closeTo(24, 0.5),
      reason: '封面贴右边（信息列的右边距）',
    );
    expect(cover.top - content.top, closeTo(20, 0.5), reason: '封面贴顶边，落在右上角');
  });

  testWidgets('改完字段点保存，回调收到新标签与歌词原文', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    TrackTags? savedTags;
    String? savedLyrics;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async {
        savedTags = tags;
        savedLyrics = lyrics;
      },
    );

    await tester.enterText(find.widgetWithText(TextField, '标题'), '  夜航（重制）  ');
    await tester.enterText(find.widgetWithText(TextField, '专辑'), '深夜频道 II');
    await tester.enterText(find.widgetWithText(TextField, '流派'), '');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(savedTags, isNotNull);
    expect(savedTags!.title, '夜航（重制）', reason: '首尾空格要去掉');
    expect(savedTags!.album, '深夜频道 II');
    expect(savedTags!.genre, '', reason: '清空表示删掉这个标签');
    expect(savedTags!.artist, '林间电台', reason: '没改的字段原样带上');
    expect(savedLyrics, _lrc);
    expect(find.byType(TrackMetadataDialog), findsNothing, reason: '保存后关闭');
  });

  testWidgets('标题清空时拦住保存并提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    int saves = 0;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => saves += 1,
    );

    await tester.enterText(find.widgetWithText(TextField, '标题'), '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();

    expect(saves, 0);
    expect(find.textContaining('标题不能为空'), findsOneWidget);
    expect(find.byType(TrackMetadataDialog), findsOneWidget, reason: '弹窗不关闭');
  });

  testWidgets('保存失败时弹窗留着并说明原因', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => throw Exception('文件只读'),
    );

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.byType(TrackMetadataDialog), findsOneWidget);
  });

  testWidgets('整体提前 1 秒 200 毫秒：按 -1200ms 平移并替换编辑器文本', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
}
