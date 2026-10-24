import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
          body: AlbumGridView(albums: albums, onSelect: (_) {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
  });
}
