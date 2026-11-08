import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';

/// 写一张 8×8 的 PNG 出来：封面要走真实文件才会建 `Image`，
/// 路径不存在会变成解码错误。
Future<String> _writePng(WidgetTester tester) async {
  final String path =
      '${Directory.systemTemp.path}/lamp-cover-decode-${DateTime.now().microsecondsSinceEpoch}.png';
  final Uint8List bytes = (await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xFF336699),
    );
    final ui.Image image = await recorder.endRecording().toImage(8, 8);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return data!.buffer.asUint8List();
  }))!;
  File(path).writeAsBytesSync(bytes);
  return path;
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

/// 当前 `Image` 用的解码宽度
int _decodeWidth(WidgetTester tester) {
  final Image image = tester.widget<Image>(find.byType(Image));
  return (image.image as ResizeImage).width ?? 0;
}

void main() {
  test('解码宽度向上取到固定档位，不再是「每个尺寸一份」', () {
    expect(coverDecodeWidth(240, 1.0), 256);
    expect(coverDecodeWidth(40, 1.25), 56);
    // 超过最大档就封顶，别去解一张 4K 的封面
    expect(coverDecodeWidth(3000, 2.0), coverDecodeSteps.last);
  });

  test('档位之间差得不多也不重叠', () {
    for (int i = 1; i < coverDecodeSteps.length; i++) {
      final double ratio = coverDecodeSteps[i] / coverDecodeSteps[i - 1];
      expect(ratio, lessThanOrEqualTo(1.3), reason: '相邻档差太多会让封面明显变糊');
    }
  });

  testWidgets('尺寸小幅变化时沿用同一份解码结果', (WidgetTester tester) async {
    final String path = await _writePng(tester);
    addTearDown(() => File(path).deleteSync());

    await tester.pumpWidget(_wrap(AlbumCover(path: path, size: 240)));
    await tester.pumpAndSettle();
    final int first = _decodeWidth(tester);

    // 侧边栏展开 / 收起就是这个量级的变化：不能每帧换一份解码结果
    await tester.pumpWidget(_wrap(AlbumCover(path: path, size: 280)));
    await tester.pumpAndSettle();
    expect(
      _decodeWidth(tester),
      first,
      reason: '变化不到 20% 时应当沿用，否则动画里每帧都要重解全部封面',
    );

    // 真的变大很多时才换档
    await tester.pumpWidget(_wrap(AlbumCover(path: path, size: 620)));
    await tester.pumpAndSettle();
    expect(_decodeWidth(tester), greaterThan(first));
  });
}
