import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';

/// 封面的 Hero 飞行（2026-11-01）：阴影必须跟着一起飞。
///
/// 以前 shuttle 只画封面本体、阴影挂在页面那棵子树上，而 Hero 飞行时两端子树
/// 都换成占位 SizedBox —— 整个飞行过程画面上没有一圈暗边，落地那一帧才补出来，
/// 看着就是「封面先移过去、再原地长出阴影」。
const Key _shot = ValueKey<String>('shot');
const Widget _cover = ColoredBox(color: Color(0xFFCC2233));

class _Shot {
  _Shot(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;

  int _lum(int x, int y) {
    final int i = (y * width + x) * 4;
    return (bytes[i] * 299 + bytes[i + 1] * 587 + bytes[i + 2] * 114) ~/ 1000;
  }

  /// 封面本体的包围盒：靠红通道认，图上只有封面是红的
  Rect coverRect() {
    int minX = width, minY = height, maxX = -1, maxY = -1;
    for (int y = 0; y < height; y += 1) {
      for (int x = 0; x < width; x += 1) {
        final int i = (y * width + x) * 4;
        if (bytes[i] > 150 && bytes[i + 1] < 90 && bytes[i + 2] < 90) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    return Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      maxX.toDouble() + 1,
      maxY.toDouble() + 1,
    );
  }

  /// 封面之外、比纯白暗的像素——也就是阴影
  int shadowPixels(Rect cover) {
    int n = 0;
    for (int y = 0; y < height; y += 1) {
      for (int x = 0; x < width; x += 1) {
        if (cover.inflate(1).contains(Offset(x.toDouble(), y.toDouble()))) {
          continue;
        }
        if (_lum(x, y) < 252) {
          n += 1;
        }
      }
    }
    return n;
  }
}

Widget _listPage() => Scaffold(
  backgroundColor: Colors.white,
  body: Center(
    child: Hero(
      tag: coverHeroTag,
      // 真实页面两边都是线性 RectTween：默认的 MaterialRectArcTween 让四个角
      // 各走各的弧，中途不是正方形
      createRectTween: (Rect? begin, Rect? end) =>
          RectTween(begin: begin, end: end),
      child: const SizedBox(width: 56, height: 56, child: _cover),
    ),
  ),
);

Widget _detailPage({required bool shadowInShuttle}) {
  final Widget cover = const SizedBox(width: 336, height: 336, child: _cover);
  return Scaffold(
    backgroundColor: Colors.white,
    body: Center(
      child: Hero(
        tag: coverHeroTag,
        createRectTween: (Rect? begin, Rect? end) =>
            RectTween(begin: begin, end: end),
        flightShuttleBuilder: (_, _, _, _, _) => shadowInShuttle
            ? coverFlightShuttle(size: 336, cover: cover)
            // 对照组：只有封面本体（旧行为）
            : FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: 336,
                  height: 336,
                  child: RepaintBoundary(child: cover),
                ),
              ),
        child: CoverShadow(radius: 28, child: cover),
      ),
    ),
  );
}

Future<_Shot> _midFlight(WidgetTester tester, {required bool shadow}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          RepaintBoundary(key: _shot, child: child ?? const SizedBox()),
      home: _listPage(),
    ),
  );
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, _, _) => _detailPage(shadowInShuttle: shadow),
        ),
      );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));

  late _Shot shot;
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary = tester.renderObject(
      find.byKey(_shot),
    );
    final ui.Image image = await boundary.toImage();
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    shot = _Shot(data!.buffer.asUint8List(), image.width, image.height);
    image.dispose();
  });
  return shot;
}

void main() {
  testWidgets('飞行中途就看得到阴影，落地不靠「补一个」', (WidgetTester tester) async {
    final _Shot plain = await _midFlight(tester, shadow: false);
    await tester.pumpWidget(const SizedBox());
    final _Shot shadowed = await _midFlight(tester, shadow: true);

    final Rect plainRect = plain.coverRect();
    final Rect shadowRect = shadowed.coverRect();

    // 阴影只是往边界盒外扩，不能改变封面本身的飞行几何
    expect(shadowRect.left, closeTo(plainRect.left, 1));
    expect(shadowRect.top, closeTo(plainRect.top, 1));
    expect(shadowRect.width, closeTo(plainRect.width, 1));
    expect(shadowRect.height, closeTo(plainRect.height, 1));

    expect(plain.shadowPixels(plainRect), 0, reason: '对照组本来就没有阴影');
    expect(
      shadowed.shadowPixels(shadowRect),
      greaterThan(3000),
      reason: '飞行中途就该看到一圈阴影，而不是落地才冒出来',
    );
  });
}
