import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/lyrics_editor_dialog.dart';
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
const String _filePath = r'E:\Music\夜航\Afterglow_(2020)-littlealone100.flac';

/// 用 `showDialog` 打开（跟真机一致）：直接塞进 `Scaffold` 的话保存后
/// `Navigator.pop` 会把唯一的路由弹掉，测不出「界面关掉了」
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
                filePath: _filePath,
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

/// 这个界面是 1120×760：默认 800×600 的测试窗口放不下，每个用例都先放大
void _bigWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('大标题、文件名与八个字段都在，字段按标签预填', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);

    expect(find.text('编辑音频信息'), findsOneWidget);
    expect(
      find.text('Afterglow_(2020)-littlealone100.flac'),
      findsOneWidget,
      reason: '副标题显示文件名而不是整条路径',
    );
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
        find.byKey(ValueKey<String>('metadata-field-$label')),
        findsOneWidget,
        reason: '缺少字段：$label',
      );
    }
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('metadata-field-标题')),
          )
          .controller!
          .text,
      '夜航',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('metadata-field-专辑')),
          )
          .controller!
          .text,
      '深夜频道',
    );
  });

  testWidgets('封面在左边、表单在右边，界面做到 1120×760', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);

    // 内容列（`SizedBox` 里已经扣掉左右 28、上下 22/18 的页边距）：
    // 1120-56 × 760-40。不用 Dialog 的矩形——它含全屏留白
    final Rect content = tester.getRect(find.byType(Column).first);
    expect(content.width, closeTo(1064, 1));
    expect(content.height, closeTo(720, 1));

    final Rect cover = tester.getRect(find.byType(AlbumCover));
    final Rect titleField = tester.getRect(
      find.byKey(const ValueKey<String>('metadata-field-标题')),
    );
    expect(cover.width, closeTo(320, 0.5), reason: '封面是卡片的视觉主体');
    expect(cover.left - content.left, lessThan(60), reason: '封面贴左边');
    expect(titleField.left, greaterThan(cover.right), reason: '表单排在封面右侧，不压在图上');
  });

  testWidgets('改完字段点保存，回调收到新标签与歌词原文', (WidgetTester tester) async {
    _bigWindow(tester);

    TrackTags? savedTags;
    String? savedLyrics;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async {
        savedTags = tags;
        savedLyrics = lyrics;
      },
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('metadata-field-标题')),
      '  夜航（重制）  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('metadata-field-专辑')),
      '深夜频道 II',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('metadata-field-流派')),
      '',
    );
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
    _bigWindow(tester);

    int saves = 0;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => saves += 1,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('metadata-field-标题')),
      '   ',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();

    expect(saves, 0);
    expect(find.textContaining('标题不能为空'), findsOneWidget);
    expect(find.byType(TrackMetadataDialog), findsOneWidget, reason: '界面不关闭');
  });

  testWidgets('保存失败时界面留着并说明原因', (WidgetTester tester) async {
    _bigWindow(tester);

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

  testWidgets('歌词是入口而不是输入框：只显示来源与行数', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester);

    expect(find.text('来自 .lrc · 3 行'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('lyrics-editor')),
      findsNothing,
      reason: '歌词编辑搬进子窗了',
    );
    expect(find.widgetWithText(OutlinedButton, '编辑歌词…'), findsOneWidget);
  });

  testWidgets('没有歌词时入口说明是空的', (WidgetTester tester) async {
    _bigWindow(tester);
    await _open(tester, lyrics: '', source: 'none');

    expect(find.textContaining('还没有内容'), findsOneWidget);
  });

  testWidgets('点「编辑歌词…」打开子窗，回来保存的是改过的歌词', (WidgetTester tester) async {
    _bigWindow(tester);

    String? savedLyrics;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => savedLyrics = lyrics,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '编辑歌词…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LyricsEditorDialog), findsOneWidget);

    const String edited = '[00:10.00]改过的第一行\n';
    await tester.enterText(
      find.byKey(const ValueKey<String>('lyrics-editor')),
      edited,
    );
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(LyricsEditorDialog), findsNothing);
    expect(find.text('来自 .lrc · 1 行'), findsOneWidget, reason: '入口摘要要跟着变');

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(savedLyrics, edited);
  });

  testWidgets('歌词子窗里点取消，原来的歌词不变', (WidgetTester tester) async {
    _bigWindow(tester);

    String? savedLyrics;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => savedLyrics = lyrics,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '编辑歌词…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.byKey(const ValueKey<String>('lyrics-editor')),
      '[00:10.00]不该被保存\n',
    );
    // 父界面也有一个「取消」：限定在歌词子窗里点
    await tester.tap(
      find.descendant(
        of: find.byType(LyricsEditorDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(LyricsEditorDialog), findsNothing);
    expect(find.text('来自 .lrc · 3 行'), findsOneWidget, reason: '行数没变');

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(savedLyrics, _lrc, reason: '取消等于没改');
  });
}
