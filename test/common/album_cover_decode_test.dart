import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/widgets/cover_flight.dart';

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

  testWidgets('decodeScale 按显示尺寸打折解码：圆头像省掉被裁掉的那圈', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final String path = await _writePng(tester);
    addTearDown(() => File(path).deleteSync());

    await tester.pumpWidget(_wrap(AlbumCover(path: path, size: 240)));
    await tester.pumpAndSettle();
    final int full = _decodeWidth(tester);

    await tester.pumpWidget(
      _wrap(AlbumCover(path: path, size: 240, decodeScale: 0.75)),
    );
    await tester.pumpAndSettle();
    expect(
      _decodeWidth(tester),
      coverDecodeWidth(180, 1),
      reason: '0.75 档：按 180 取档，位图与纹理都只剩一半左右',
    );
    expect(_decodeWidth(tester), lessThan(full));

    // 再小就没意义了（头像糊成一片），下限夹在 0.3
    await tester.pumpWidget(
      _wrap(AlbumCover(path: path, size: 240, decodeScale: 0.05)),
    );
    await tester.pumpAndSettle();
    expect(_decodeWidth(tester), coverDecodeWidth(72, 1));
  });

  testWidgets('封面飞行按小端取解码档，不往缓存里塞大端死条目', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final String path = await _writePng(tester);
    addTearDown(() => File(path).deleteSync());

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            host = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );

    // 卡片 160 → 详情头部 240：飞行盒子取 240，但解码该按 160 那一档
    final VoidCallback cancel = flyCover(
      host,
      from: const Rect.fromLTWH(0, 0, 160, 160),
      to: const Rect.fromLTWH(300, 200, 240, 240),
      buildCover: (double size, double radius, double scale) => AlbumCover(
        path: path,
        size: size,
        radius: radius,
        decodeScale: scale,
      ),
      onDone: () {},
    );
    addTearDown(cancel);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(
      _decodeWidth(tester),
      coverDecodeWidth(160, 1),
      reason: '飞行那张按小端解，落地后再由真实封面按大端解',
    );
    await tester.pumpAndSettle();
  });
}
