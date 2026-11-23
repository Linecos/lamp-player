import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/library_sort.dart';
import 'package:lamp_player/src/features/library/widgets/collection_grids.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

void main() {
  testWidgets('专辑网格在有封面时渲染图片', (WidgetTester tester) async {
    final Directory dir = Directory.systemTemp.createTempSync('lamp-covers');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File cover = File('${dir.path}/cover.png');
    cover.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    final List<AlbumGroup> albums = groupTracksByAlbum(<Track>[
      sampleTrack(
        title: '夜航',
        artist: '林间电台',
        album: '夜航',
        coverPath: cover.path,
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: AlbumGridView(albums: albums, onSelect: (_, _, _) {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('艺术家网格的圆头像按满档解码，不能比旁边专辑卡糊', (WidgetTester tester) async {
    // 圆形头像只裁掉四个角，圆内那部分像素密度一点没省。曾经按 0.75 档解码：
    // 160 的头像解成 192px，铺到 240 物理像素上（150% 缩放）就是放大 1.25 倍，
    // 和旁边按 256 解、1:1 画的专辑封面一比明显糊。
    const double dpr = 1.5;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = const Size(1350, 1050);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final Directory dir = Directory.systemTemp.createTempSync('lamp-covers');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File cover = File('${dir.path}/cover.png');
    cover.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    final List<ArtistGroup> artists = groupTracksByArtist(<Track>[
      sampleTrack(title: '夜航', artist: '林间电台', coverPath: cover.path),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: ArtistGridView(artists: artists, onSelect: (_, _, _) {}),
        ),
      ),
    );
    await tester.pump();

    final Image image = tester.widget<Image>(find.byType(Image));
    final int decode = (image.image as ResizeImage).width!;
    final double shown = tester.getSize(find.byType(AlbumCover)).width * dpr;
    expect(
      decode,
      greaterThanOrEqualTo(shown),
      reason: '解码宽度不能小于显示尺寸，否则位图被放大着画就是糊的',
    );
  });
}
