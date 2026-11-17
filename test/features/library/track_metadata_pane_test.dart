import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/lyrics_editor_dialog.dart';
import 'package:lamp_player/src/features/library/widgets/track_metadata_pane.dart';
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

/// 区块在内容区里是「一屏」大小：给个固定盒子，免得跟着默认 800×600 挤
Future<void> _open(
  WidgetTester tester, {
  String lyrics = _lrc,
  String source = 'sidecar',
  String? coverPath,
  TrackTags? tags,
  Future<String> Function(String text, int deltaMs)? onShiftLyrics,
  Future<void> Function(TrackTags tags, String lyrics)? onSave,
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 1000,
            height: 1000,
            child: TrackMetadataPane(
              filePath: _filePath,
              coverPath: coverPath,
              tags: tags ?? _tags(),
              lyricsText: lyrics,
              lyricsSource: source,
              onShiftLyrics:
                  onShiftLyrics ?? (String text, int deltaMs) async => text,
              onSave: onSave ?? (TrackTags tags, String lyrics) async {},
              onClose: onClose ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _field(String label) =>
    find.byKey(ValueKey<String>('metadata-field-$label'));

String _textOf(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void main() {
  testWidgets('大标题、文件名与八个字段都在，字段按标签预填', (WidgetTester tester) async {
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
      expect(_field(label), findsOneWidget, reason: '缺少字段：$label');
    }
    expect(_textOf(tester, '标题'), '夜航');
    expect(_textOf(tester, '专辑'), '深夜频道');
    expect(_textOf(tester, '流派'), 'Ambient');
  });

  testWidgets('封面在左、表单在右', (WidgetTester tester) async {
    await _open(tester);

    final Rect cover = tester.getRect(find.byType(AlbumCover));
    final Rect titleField = tester.getRect(_field('标题'));
    expect(cover.width, closeTo(280, 0.5), reason: '宽 1000 时封面取 28%');
    expect(titleField.left, greaterThan(cover.right), reason: '表单不压在图上');
    expect(
      (titleField.top - cover.top).abs(),
      lessThan(80),
      reason: '封面与第一个字段大致齐头',
    );
  });

  testWidgets('改完字段点保存：回调收到新标签，然后关闭', (WidgetTester tester) async {
    TrackTags? savedTags;
    String? savedLyrics;
    int closes = 0;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async {
        savedTags = tags;
        savedLyrics = lyrics;
      },
      onClose: () => closes += 1,
    );

    await tester.enterText(_field('标题'), '  夜航（重制）  ');
    await tester.enterText(_field('专辑'), '深夜频道 II');
    await tester.enterText(_field('流派'), '');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(savedTags, isNotNull);
    expect(savedTags!.title, '夜航（重制）', reason: '首尾空格要去掉');
    expect(savedTags!.album, '深夜频道 II');
    expect(savedTags!.genre, '', reason: '清空表示删掉这个标签');
    expect(savedTags!.artist, '林间电台', reason: '没改的字段原样带上');
    expect(savedLyrics, _lrc);
    expect(closes, 1, reason: '保存成功后由外面把区块换回原分区');
  });

  testWidgets('标题清空时拦住保存并提示', (WidgetTester tester) async {
    int saves = 0;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => saves += 1,
    );

    await tester.enterText(_field('标题'), '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();

    expect(saves, 0);
    expect(find.textContaining('标题不能为空'), findsOneWidget);
  });

  testWidgets('保存失败时留在区块里并说明原因', (WidgetTester tester) async {
    int closes = 0;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => throw Exception('文件只读'),
      onClose: () => closes += 1,
    );

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(closes, 0, reason: '失败不该把区块关掉');
  });

  testWidgets('返回箭头与「取消」都只是退出，不保存', (WidgetTester tester) async {
    int closes = 0;
    int saves = 0;
    await _open(
      tester,
      onSave: (TrackTags tags, String lyrics) async => saves += 1,
      onClose: () => closes += 1,
    );

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    expect(closes, 1);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    expect(closes, 2);
    expect(saves, 0);
  });

  testWidgets('歌词是入口而不是输入框：只显示来源与行数', (WidgetTester tester) async {
    await _open(tester);

    expect(find.text('来自 .lrc · 3 行'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('lyrics-editor')),
      findsNothing,
      reason: '歌词编辑在子窗里',
    );
    expect(find.widgetWithText(OutlinedButton, '编辑歌词…'), findsOneWidget);
  });

  testWidgets('没有歌词时入口说明是空的', (WidgetTester tester) async {
    await _open(tester, lyrics: '', source: 'none');

    expect(find.textContaining('还没有内容'), findsOneWidget);
  });

  testWidgets('点「编辑歌词…」打开子窗，回来保存的是改过的歌词', (WidgetTester tester) async {
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
    await tester.pump(const Duration(milliseconds: 50));
    expect(savedLyrics, edited);
  });

  testWidgets('歌词子窗里点取消，原来的歌词不变', (WidgetTester tester) async {
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
    await tester.pump(const Duration(milliseconds: 50));
    expect(savedLyrics, _lrc, reason: '取消等于没改');
  });
}
