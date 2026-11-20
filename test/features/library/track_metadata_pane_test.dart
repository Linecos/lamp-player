import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/lyrics_editor_dialog.dart';
import 'package:lamp_player/src/features/library/widgets/track_metadata_pane.dart';
import 'package:lamp_player/src/rust/api/metadata.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';

TrackTags _tags({
  String title = '夜航',
  String artist = '林间电台',
  String album = '深夜频道',
  String albumArtist = '',
  String year = '2003',
  String trackNo = '3',
  String discNo = '',
  String genre = 'Ambient',
  String composer = '坂本龍一',
  String lyricist = '佚名',
  String comment = '录音室版',
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
    composer: composer,
    lyricist: lyricist,
    comment: comment,
  );
}

const String _lrc = '[ti:夜航]\n[00:10.00]第一行\n[00:20.00]第二行\n';
const String _filePath = r'E:\Music\夜航\Afterglow_(2020)-littlealone100.flac';

/// 曲库里那一条：信息卡片的数值都从它来
Track _track() => sampleTrack(
  title: '夜航',
  album: '深夜频道',
  path: _filePath,
  durationSecs: 250,
  trackNum: 1,
  fileSize: 58342752, // 55.64 MB
  audioBitrate: 1819,
  sampleRate: 48000,
  bitDepth: 24,
  truePeak: 0.98,
  replayGain: -7.62,
);

/// 区块在内容区里是「一屏」大小：给个固定盒子，免得跟着默认 800×600 挤
Future<void> _open(
  WidgetTester tester, {
  String lyrics = _lrc,
  String source = 'sidecar',
  String? coverPath,
  TrackTags? tags,
  Future<String> Function(String text, int deltaMs)? onShiftLyrics,
  Future<String?> Function()? onPickCover,
  Future<void> Function(MetadataDraft draft)? onSave,
  VoidCallback? onClose,
  Track? track,
  Future<int?> Function()? onProbeChannels,
  double height = 1000,
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
            height: height,
            child: TrackMetadataPane(
              // 同一测试里换参数再 pump 时，要整块重建（controller 与
              // 「歌词写到哪儿」都在 State 里）
              key: ValueKey<String>('pane-$source-$lyrics'),
              filePath: _filePath,
              track: track ?? _track(),
              onProbeChannels: onProbeChannels,
              coverPath: coverPath,
              tags: tags ?? _tags(),
              lyricsText: lyrics,
              lyricsSource: source,
              onShiftLyrics:
                  onShiftLyrics ?? (String text, int deltaMs) async => text,
              onPickCover: onPickCover ?? () async => null,
              onSave: onSave ?? (MetadataDraft draft) async {},
              onClose: onClose ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // 声道数与文件时间是真实 IO（这里路径不存在，stat 会抛）：放出去跑一下，
  // 免得断言时它们还没回来
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Finder _field(String label) =>
    find.byKey(ValueKey<String>('metadata-field-$label'));

String _textOf(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void main() {
  testWidgets('标题区不挤：大标题与文件名之间留了空，且不显示整条路径', (WidgetTester tester) async {
    await _open(tester);

    expect(find.text('编辑音频信息'), findsOneWidget);
    final Finder name = find.text('Afterglow_(2020)-littlealone100.flac');
    expect(name, findsOneWidget, reason: '副标题显示文件名而不是整条路径');
    // CI 跑在 ubuntu 上：若哪天真用了按平台风格切分的 `p.basename`，
    // Windows 路径在那边切不开，这里会整条路径显示出来 —— 这条断言就是
    // 为它守的（本地 Windows 看不出差别）。
    // 整条路径只在下面「存储信息」那张卡片里出现，标题区不能有
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('metadata-info-存储信息')),
        matching: find.text(_filePath),
      ),
      findsOneWidget,
      reason: '整条路径只出现在存储信息卡片里',
    );
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Padding &&
              widget.padding == const EdgeInsets.only(top: 2, bottom: 16),
        ),
        matching: find.text(_filePath),
      ),
      findsNothing,
      reason: '标题区不能出现整条路径',
    );

    final double titleBottom = tester.getRect(find.text('编辑音频信息')).bottom;
    final double nameTop = tester.getRect(name).top;
    expect(
      nameTop - titleBottom,
      greaterThanOrEqualTo(4),
      reason: '标题与文件名贴在一起就是「挤」的根源：$titleBottom / $nameTop',
    );
  });

  testWidgets('十二个字段都在，且按标签预填', (WidgetTester tester) async {
    await _open(tester);

    for (final String label in <String>[
      '标题',
      '艺术家',
      '专辑',
      '年份',
      '音轨号',
      '流派',
      '专辑艺术家',
      '作曲家',
      '作词家',
      '注释',
      '碟号',
    ]) {
      expect(_field(label), findsOneWidget, reason: '缺少字段：$label');
    }
    // 歌词是第 12 项，做成了入口而不是输入框
    expect(find.text('歌词'), findsOneWidget);

    expect(_textOf(tester, '标题'), '夜航');
    expect(_textOf(tester, '专辑'), '深夜频道');
    expect(_textOf(tester, '流派'), 'Ambient');
    expect(_textOf(tester, '作曲家'), '坂本龍一');
    expect(_textOf(tester, '作词家'), '佚名');
    expect(_textOf(tester, '注释'), '录音室版');
  });

  testWidgets('封面在左、表单在右，封面尺寸有上限', (WidgetTester tester) async {
    await _open(tester);

    final Rect cover = tester.getRect(find.byType(AlbumCover));
    final Rect titleField = tester.getRect(_field('标题'));
    expect(cover.width, closeTo(200, 0.5), reason: '宽 1000 时封面取 200 上限');
    expect(titleField.left, greaterThan(cover.right), reason: '表单不压在图上');
    expect(
      (titleField.top - cover.top).abs(),
      lessThan(80),
      reason: '封面与第一个字段大致齐头',
    );
  });

  testWidgets('点封面才去选图，选完先显示新图，保存前不落盘', (WidgetTester tester) async {
    int picks = 0;
    await _open(
      tester,
      onPickCover: () async {
        picks += 1;
        return r'D:\Pictures\new-cover.png';
      },
    );

    expect(find.text('点击封面可以换一张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('metadata-cover-pick')));
    await tester.pump();

    expect(picks, 1);
    expect(find.text('保存后生效'), findsOneWidget, reason: '提示要跟着变，否则用户不知道有没有生效');
    expect(find.byType(AlbumCover), findsNothing, reason: '预览换成选中的那张');
  });

  testWidgets('保存时把新封面路径一起交出去', (WidgetTester tester) async {
    MetadataDraft? draft;
    await _open(
      tester,
      onPickCover: () async => r'D:\Pictures\new-cover.png',
      onSave: (MetadataDraft value) async => draft = value,
    );

    await tester.tap(find.byKey(const ValueKey<String>('metadata-cover-pick')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(draft?.coverSource, r'D:\Pictures\new-cover.png');
  });

  testWidgets('改完字段点保存：回调收到新标签，然后关闭', (WidgetTester tester) async {
    MetadataDraft? draft;
    int closes = 0;
    await _open(
      tester,
      onSave: (MetadataDraft value) async => draft = value,
      onClose: () => closes += 1,
    );

    await tester.enterText(_field('标题'), '  夜航（重制）  ');
    await tester.enterText(_field('专辑'), '深夜频道 II');
    await tester.enterText(_field('流派'), '');
    await tester.enterText(_field('作曲家'), ' 坂本龍一 ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(draft, isNotNull);
    expect(draft!.tags.title, '夜航（重制）', reason: '首尾空格要去掉');
    expect(draft!.tags.album, '深夜频道 II');
    expect(draft!.tags.genre, '', reason: '清空表示删掉这个标签');
    expect(draft!.tags.composer, '坂本龍一');
    expect(draft!.tags.artist, '林间电台', reason: '没改的字段原样带上');
    expect(draft!.lyrics, _lrc);
    expect(draft!.coverSource, isNull, reason: '没换封面就别写');
    expect(closes, 1, reason: '保存成功后由外面把区块换回原分区');
  });

  testWidgets('标题清空时拦住保存并提示', (WidgetTester tester) async {
    int saves = 0;
    await _open(tester, onSave: (MetadataDraft draft) async => saves += 1);

    await tester.enterText(_field('标题'), '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();

    expect(saves, 0);
    expect(find.textContaining('标题不能为空'), findsOneWidget);
    // 提示紧挨着按钮（标题行），不跟着只读内容一起压到底部
    expect(
      tester.getRect(find.textContaining('标题不能为空')).top,
      lessThan(tester.getRect(_field('标题')).top),
    );
  });

  testWidgets('保存失败时留在区块里并说明原因', (WidgetTester tester) async {
    int closes = 0;
    await _open(
      tester,
      onSave: (MetadataDraft draft) async => throw Exception('文件只读'),
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
      onSave: (MetadataDraft draft) async => saves += 1,
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

  testWidgets('歌词写入位置默认跟着来源走', (WidgetTester tester) async {
    await _open(tester);
    SegmentedButton<bool> target() => tester.widget<SegmentedButton<bool>>(
      find.byKey(const ValueKey<String>('metadata-lyrics-target')),
    );
    expect(target().selected, <bool>{false}, reason: '旁载歌词默认还写 .lrc');

    await _open(tester, source: 'embedded');
    expect(target().selected, <bool>{true}, reason: '内嵌歌词默认还写标签');
  });

  testWidgets('切成「音频标签」后保存，draft 里带上这个选择', (WidgetTester tester) async {
    MetadataDraft? draft;
    await _open(tester, onSave: (MetadataDraft value) async => draft = value);

    await tester.tap(find.text('音频标签'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(draft?.embedLyrics, isTrue);
    expect(find.textContaining('写进音频文件'), findsNothing);
  });

  testWidgets('点「编辑歌词…」打开子窗，回来保存的是改过的歌词', (WidgetTester tester) async {
    MetadataDraft? draft;
    await _open(tester, onSave: (MetadataDraft value) async => draft = value);

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
    expect(draft?.lyrics, edited);
  });

  testWidgets('歌词子窗里点取消，原来的歌词不变', (WidgetTester tester) async {
    MetadataDraft? draft;
    await _open(tester, onSave: (MetadataDraft value) async => draft = value);

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
    expect(draft?.lyrics, _lrc, reason: '取消等于没改');
  });

  testWidgets('表单下面是三张信息卡：音频参数 / 电平与增益 / 存储信息', (WidgetTester tester) async {
    int probes = 0;
    await _open(
      tester,
      onProbeChannels: () async {
        probes += 1;
        return 2;
      },
    );
    // 声道数是异步探测的：再走一帧才落到界面上
    await tester.pump();

    for (final String title in <String>['音频参数', '电平与增益', '存储信息']) {
      expect(
        find.byKey(ValueKey<String>('metadata-info-$title')),
        findsOneWidget,
        reason: '缺少卡片：$title',
      );
    }
    expect(probes, 1, reason: '声道数只在打开时探一次');

    // 位置：三张卡片在表单卡片下面（不是挤在表单里）
    final Rect firstCard = tester.getRect(
      find.byKey(const ValueKey<String>('metadata-info-音频参数')),
    );
    expect(
      firstCard.top,
      greaterThan(tester.getRect(_field('注释')).bottom),
      reason: '信息卡在表单下面',
    );

    // 数值
    expect(find.text('04:10'), findsOneWidget, reason: '250 秒');
    expect(find.text('1819 kbps'), findsOneWidget);
    expect(find.text('48000 Hz'), findsOneWidget);
    expect(find.text('24 bit'), findsOneWidget);
    expect(find.text('2 声道'), findsOneWidget);
    expect(find.text('1'), findsWidgets, reason: '音轨编号');
    expect(find.text('0.98'), findsOneWidget, reason: '真峰值优先');
    expect(find.text('-7.62 dB'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('55.64 MB'), findsOneWidget);
    // 测试里的路径不存在：文件时间读不到、增益没分析过，都显示「—」
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('探测不到声道数时不崩，显示未知', (WidgetTester tester) async {
    await _open(tester, onProbeChannels: () async => throw Exception('文件读不了'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('metadata-info-音频参数')),
      findsOneWidget,
    );
    expect(find.text('2 声道'), findsNothing);
  });

  testWidgets('保存 / 取消在标题行：滚到底也不用回头找按钮', (WidgetTester tester) async {
    // 盒子矮一点，内容比一屏高，才测得出「滚了按钮也还在原位」
    await _open(tester, height: 620);

    final Finder save = find.widgetWithText(FilledButton, '保存');
    final Finder cancel = find.widgetWithText(TextButton, '取消');
    final Rect saveBefore = tester.getRect(save);
    final Rect cancelBefore = tester.getRect(cancel);
    expect(
      saveBefore.bottom,
      lessThan(tester.getRect(_field('标题')).top),
      reason: '按钮在表单上面，而不是等滚到底才出现',
    );

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();

    final double offset = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .pixels;
    expect(offset, greaterThan(100), reason: '内容确实滚动了');

    expect(tester.getRect(save), saveBefore, reason: '保存按钮不随内容滚动');
    expect(tester.getRect(cancel), cancelBefore, reason: '取消按钮不随内容滚动');
  });

  test('时长 / 大小 / 时间这些边角值', () {
    expect(formatTrackDuration(250), '04:10');
    expect(formatTrackDuration(3725), '1:02:05', reason: '满一小时要带上小时位');
    expect(formatTrackDuration(0), '—');
    expect(formatTrackDuration(double.nan), '—');
    expect(formatFileSize(58342752), '55.64 MB');
    expect(formatFileSize(800 * 1024), '800.0 KB');
    expect(formatFileSize(0), '—');
    expect(formatFileFormat(r'D:\Music\a.flac'), 'FLAC');
    expect(formatFileFormat(r'D:\Music\没有扩展名'), '未知');
    expect(formatChannels(1), '单声道');
    expect(formatChannels(2), '2 声道');
    expect(formatChannels(0), '—');
    expect(formatPeak(0), '—');
    expect(formatGainDb(0), '—', reason: '0 表示标签里没有这个值');
    expect(formatLoudness(0), '—');
    expect(formatLoudness(-14.28), '-14.3 LUFS');
    expect(formatMoment(null), '—');
    expect(
      formatMoment(DateTime(2026, 8, 13, 15, 5, 24)),
      '2026-08-13 15:05:24',
    );
  });
}
