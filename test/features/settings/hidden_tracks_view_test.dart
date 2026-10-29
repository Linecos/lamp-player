import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/settings/hidden_tracks_view.dart';
import 'package:lamp_player/src/rust/api/db.dart' as db;

db.HiddenTrack _item({
  String title = '夜航',
  String artist = '林间电台',
  String album = '夜之专辑',
  double duration = 180,
  String cover = '',
  String path = '/music/night.mp3',
}) {
  return db.HiddenTrack(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationSecs: duration,
    coverPath: cover,
    hiddenAt: 0,
  );
}

Future<void> _pump(
  WidgetTester tester,
  List<db.HiddenTrack> items, {
  ValueChanged<db.HiddenTrack>? onRestore,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: SizedBox(
          width: 560,
          height: 360,
          child: HiddenTracksView(
            items: items,
            onRestore: onRestore ?? (db.HiddenTrack _) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('每行都有封面、曲名、歌手·专辑与时长', (WidgetTester tester) async {
    await _pump(tester, <db.HiddenTrack>[
      _item(),
      _item(title: '潮汐', artist: '海边的卡夫卡', album: '潮汐', duration: 95),
    ]);

    // 封面缺失时是回退图标，但 AlbumCover 本身每行都要有一个（和曲库列表一致）
    expect(find.byType(AlbumCover), findsNWidgets(2));
    expect(tester.widget<AlbumCover>(find.byType(AlbumCover).first).size, 40);
    expect(
      tester.widget<AlbumCover>(find.byType(AlbumCover).first).radius,
      12,
      reason: '与曲目列表的 40/12 同源',
    );

    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('林间电台 · 夜之专辑'), findsOneWidget);
    expect(find.text('03:00'), findsOneWidget);
    expect(find.text('01:35'), findsOneWidget, reason: '时长右侧对齐、等宽数字');
    expect(find.text('恢复'), findsNWidgets(2));
  });

  testWidgets('点整行或点「恢复」都触发恢复', (WidgetTester tester) async {
    final List<db.HiddenTrack> restored = <db.HiddenTrack>[];
    await _pump(tester, <db.HiddenTrack>[
      _item(),
      _item(title: '潮汐', path: '/music/tide.mp3'),
    ], onRestore: restored.add);

    await tester.tap(find.text('潮汐'));
    await tester.pumpAndSettle();
    expect(restored.single.title, '潮汐');

    await tester.tap(find.text('恢复').first);
    await tester.pumpAndSettle();
    expect(restored, hasLength(2));
    expect(restored.last.title, '夜航');
  });

  testWidgets('标题为空时用路径兜底，副标题为空则不占位', (WidgetTester tester) async {
    await _pump(tester, <db.HiddenTrack>[
      _item(title: '', artist: '', album: '', path: '/music/unknown.flac'),
    ]);

    expect(find.text('/music/unknown.flac'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('有封面时把缓存路径传给封面组件', (WidgetTester tester) async {
    await _pump(tester, <db.HiddenTrack>[
      _item(cover: '/covers/abc.jpg'),
      _item(title: '潮汐', path: '/music/tide.mp3'),
    ]);

    final List<AlbumCover> covers = tester
        .widgetList<AlbumCover>(find.byType(AlbumCover))
        .toList();
    expect(covers.first.path, '/covers/abc.jpg', reason: '隐藏列表要和曲库列表一样带封面');
    expect(covers.last.path, isNull, reason: '没有封面时交给回退图标');
  });

  testWidgets('没有封面时显示音符回退图标', (WidgetTester tester) async {
    await _pump(tester, <db.HiddenTrack>[_item()]);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });
}
