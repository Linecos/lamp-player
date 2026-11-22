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

  testWidgets('滚动中出现的封面先不进解码，冷静期过了才建 Image', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final String path = await _writePng(tester);
    addTearDown(() => File(path).deleteSync());

    // 第 2 行才有封面：初始视口只够到第 1 行，那一行是纯文字
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 200,
            child: ListView.builder(
              itemExtent: 400,
              itemCount: 6,
              itemBuilder: (BuildContext context, int index) => SizedBox(
                height: 400,
                child: index == 2
                    ? Center(child: AlbumCover(path: path, size: 240))
                    : Center(child: Text('row$index')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsNothing, reason: '开局这一屏没有封面');

    final TestGesture gesture = await tester.startGesture(
      const Offset(200, 100),
    );
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -700));
    await tester.pump();

    expect(find.byType(Image), findsNothing, reason: '封面是在滚动中挂上来的，先别读盘 + 解码');

    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(Image), findsOneWidget, reason: '冷静期一过就正常解码，不能一直空着');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('大封面卸载时把解码结果摘掉，小封面留着', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final String path = await _writePng(tester);
    addTearDown(() => File(path).deleteSync());

    ImageProvider providerOf(double size) => ResizeImage.resizeIfNeeded(
      coverDecodeWidth(size, 1),
      null,
      FileImage(File(path)),
    );

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            host = context;
            return const SizedBox();
          },
        ),
      ),
    );

    // 先把解码结果放进缓存（没有监听者 → 变成 keepAlive 条目）
    await tester.runAsync(() async {
      await precacheImage(providerOf(240), host);
      await precacheImage(providerOf(56), host);
    });
    // precacheImage 在帧末才摘监听者，摘掉之后才从 live 转成 keepAlive
    await tester.pump();
    expect(
      imageAlreadyCached(providerOf(240)),
      isTrue,
      reason: '前置条件：大图已经在缓存里',
    );

    await tester.pumpWidget(_wrap(AlbumCover(path: path, size: 240)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(
      imageAlreadyCached(providerOf(240)),
      isFalse,
      reason: '详情头图 / 播放页大图只在页面里出现一次，关掉就该还回去',
    );

    await tester.pumpWidget(_wrap(AlbumCover(path: path, size: 56)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(
      imageAlreadyCached(providerOf(56)),
      isTrue,
      reason: '列表小图留着：回滚时零成本，40MB 上限也装得下',
    );
  });
}
