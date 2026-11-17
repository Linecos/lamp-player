import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/playlist_grid.dart';
import 'package:lamp_player/src/rust/api/model.dart';

/// 歌单封面：卡片要认「自定义优先」，否则详情里换了封面、列表还显示旧的。
void main() {
  Playlist playlist({String? coverPath}) => Playlist(
    id: 7,
    name: '夜航',
    trackCount: 3,
    coverPath: coverPath,
    createdAt: 0,
    updatedAt: 0,
  );

  Future<void> pumpGrid(
    WidgetTester tester, {
    String? Function(Playlist)? coverPathOf,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistGridView(
            playlists: <Playlist>[playlist(coverPath: '/auto.jpg')],
            onOpen: (Playlist _) {},
            onAction: (Playlist _, PlaylistAction _) {},
            coverPathOf: coverPathOf,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('有自定义封面时卡片用自定义那张', (WidgetTester tester) async {
    await pumpGrid(tester, coverPathOf: (Playlist _) => '/custom.jpg');

    final AlbumCover cover = tester.widget<AlbumCover>(
      find.byType(AlbumCover).first,
    );
    expect(cover.path, '/custom.jpg');
  });

  testWidgets('没有自定义封面时用歌单自己的封面', (WidgetTester tester) async {
    await pumpGrid(tester, coverPathOf: (Playlist _) => null);

    final AlbumCover cover = tester.widget<AlbumCover>(
      find.byType(AlbumCover).first,
    );
    expect(cover.path, '/auto.jpg');
  });

  testWidgets('不传回调时退回歌单自带封面', (WidgetTester tester) async {
    await pumpGrid(tester);

    final AlbumCover cover = tester.widget<AlbumCover>(
      find.byType(AlbumCover).first,
    );
    expect(cover.path, '/auto.jpg');
  });
}
