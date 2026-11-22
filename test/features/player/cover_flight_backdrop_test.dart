import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/common/widgets/cover_shape.dart';

/// 封面飞起来的第一帧（2026-11-22）：点开播放详情页时封面不能先空一下。
///
/// 播放页大图和播放岛小图不是同一档解码，而大图**卸载即 evict**——每次点开
/// 都是冷解码。飞行开始的头几帧大图还没解出来，两端子树又都被 Hero 换成了
/// 占位，画面上就是「封面闪一下」。
const Key _shot = ValueKey<String>('shot');

/// 封面本身的颜色：白底、深蓝，阴影是纯灰，靠「蓝得比红多」就能分开
const Color _coverColor = Color(0xFF336699);

const double _smallSize = playerBarCoverSize;
const double _bigSize = 336;

/// 飞行中段取样：这时候飞行框（~280）比插值半径（~26）大得多，
/// 「圆」和「圆角矩形」才分得出来
const Duration _sampleAt = Duration(milliseconds: 240);

Future<String> _writePng(WidgetTester tester) async {
  final String path =
      '${Directory.systemTemp.path}/lamp-cover-flight-${DateTime.now().microsecondsSinceEpoch}.png';
  final Uint8List bytes = (await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = _coverColor);
    final ui.Image image = await recorder.endRecording().toImage(8, 8);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return data!.buffer.asUint8List();
  }))!;
  File(path).writeAsBytesSync(bytes);
  return path;
}

/// 播放岛那份解码结果的缓存键（与 [AlbumCover] 内部算的是同一套）
ImageProvider<Object> _smallProvider(String path) => ResizeImage.resizeIfNeeded(
  coverDecodeWidth(_smallSize, 1),
  null,
  FileImage(File(path)),
);

ImageProvider<Object> _bigProvider(String path) => ResizeImage.resizeIfNeeded(
  coverDecodeWidth(_bigSize, 1),
  null,
  FileImage(File(path)),
);

/// 页面封面 Hero 子树的身份锚：与 now_playing_page 里的 `_coverKey` 同构。
///
/// Hero 在「占位树 ↔ 正常树」之间换形时，没有它整棵封面子树会被拆掉重挂，
/// 落地那一帧 `_CoverImage` 重新解码，中间露出底下的灰色阴影盘。
final GlobalKey _pageCoverKey = GlobalKey();

Widget _barPage(String path) => Scaffold(
  backgroundColor: Colors.white,
  body: Center(
    child: Hero(
      tag: coverHeroTag,
      createRectTween: (Rect? begin, Rect? end) =>
          RectTween(begin: begin, end: end),
      child: AlbumCover(path: path, size: _smallSize, radius: 20),
    ),
  ),
);

Widget _pagePage(
  String path, {
  required bool backdrop,
  bool circular = false,
}) => Scaffold(
  backgroundColor: Colors.white,
  body: Center(
    child: Hero(
      tag: coverHeroTag,
      createRectTween: (Rect? begin, Rect? end) =>
          RectTween(begin: begin, end: end),
      flightShuttleBuilder: (_, _, _, _, _) => coverFlightShuttle(
        size: _bigSize,
        backdrop: backdrop
            ? coverFlightBackdrop(
                path: path,
                playing: false,
                circular: circular,
              )
            : null,
        cover: AlbumCover(
          path: path,
          size: _bigSize,
          radius: 0,
          circular: circular,
          // 临时副本：卸载时不能把页面那份正在用的解码结果 evict 掉
          evictOnDispose: false,
        ),
        circular: circular,
        fromSize: _smallSize,
        fromRadius: 20,
        toRadius: 28,
      ),
      // 与真实页面同构：飞行期间用 Offstage 继续挂着原封面，图片订阅不断。
      // 没有这层的话子树会在起飞那一帧就整个摘掉，State 丢失
      placeholderBuilder: (BuildContext context, Size size, Widget child) =>
          SizedBox.fromSize(
            size: size,
            child: Offstage(child: child),
          ),
      child: CoverShadow(
        key: _pageCoverKey,
        radius: 28,
        circular: circular,
        child: AlbumCover(
          path: path,
          size: _bigSize,
          radius: 28,
          circular: circular,
        ),
      ),
    ),
  ),
);

class _Shot {
  _Shot(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;

  /// 封面像素：蓝通道明显高于红通道（阴影是纯灰，过不了这一关）
  bool _isCover(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return false;
    }
    final int i = (y * width + x) * 4;
    return bytes[i + 2] - bytes[i] > 40;
  }

  Rect coverRect() {
    int minX = width, minY = height, maxX = -1, maxY = -1;
    for (int y = 0; y < height; y += 1) {
      for (int x = 0; x < width; x += 1) {
        if (!_isCover(x, y)) {
          continue;
        }
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
    return Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      maxX.toDouble() + 1,
      maxY.toDouble() + 1,
    );
  }

  int coverPixels() =>
      coverPixelsIn(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));

  int coverPixelsIn(Rect area) {
    int n = 0;
    for (int y = area.top.toInt(); y < area.bottom.toInt(); y += 1) {
      for (int x = area.left.toInt(); x < area.right.toInt(); x += 1) {
        if (_isCover(x, y)) {
          n += 1;
        }
      }
    }
    return n;
  }

  /// 包围盒四角往里一点的小方块：圆封面这里是空的，圆角矩形这里是满的。
  ///
  /// 取 20~40：圆角矩形的角半径只有 26，这块离角心（26,26）不到 15，是实心；
  /// 圆的半径是飞行框的一半，整块都落在圆外。
  static Rect cornerPatch(Rect cover) =>
      Rect.fromLTWH(cover.left + 20, cover.top + 20, 20, 20);
}

Future<_Shot> _midFlight(
  WidgetTester tester,
  String path, {
  required bool backdrop,
  bool circular = false,
  Duration sampleAt = _sampleAt,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          RepaintBoundary(key: _shot, child: child ?? const SizedBox()),
      home: _barPage(path),
    ),
  );
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, _, _) =>
              _pagePage(path, backdrop: backdrop, circular: circular),
        ),
      );
  await tester.pump();
  // 逐帧推进：一口气 pump 整段的话，飞行层卸载触发的 evict（异步）还没生效，
  // 落地那一帧会假命中缓存，测不出「重新解码」的问题
  for (
    Duration t = Duration.zero;
    t < sampleAt;
    t += const Duration(milliseconds: 16)
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }

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

Future<void> _reset(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('大图还没解出来时，飞行层先用播放岛那份小图顶上', (WidgetTester tester) async {
    final String path = await _writePng(tester);
    // 窗口上解码器可能还拿着文件句柄，删不掉不算失败
    addTearDown(() {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // 临时目录里的过期文件，系统会自己回收
      }
    });

    // 只有播放岛那份解码结果在缓存里：大图是冷的，和真实点开时一样
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
    await tester.runAsync(() async {
      await precacheImage(_smallProvider(path), host);
    });
    await tester.pump();
    expect(
      imageAlreadyCached(_smallProvider(path)),
      isTrue,
      reason: '前置条件：播放岛正在显示这份小图',
    );
    await _reset(tester);

    // 对照组：没有垫底小图（改之前的行为）——飞行层里一个封面像素都画不出来
    final _Shot plain = await _midFlight(tester, path, backdrop: false);
    expect(plain.coverPixels(), 0, reason: '大图冷解码时飞行层是空的，这就是「封面闪一下」');
    await _reset(tester);

    // 有垫底小图：飞行中途就看得到封面，尺寸与飞行框一致
    final _Shot eased = await _midFlight(tester, path, backdrop: true);
    final Rect rect = eased.coverRect();
    expect(
      eased.coverPixels(),
      greaterThan(5000),
      reason: '大图没解出来也得有东西顶上，不能空着',
    );
    // 300ms 飞行到 240ms：飞行框在 56 与 336 之间，且必须保持正方形
    expect(rect.width, inInclusiveRange(_smallSize, _bigSize));
    expect(rect.height, closeTo(rect.width, 2));
  });

  testWidgets('落地那一帧封面不能空着，别退回灰底阴影盘', (WidgetTester tester) async {
    final String path = await _writePng(tester);
    addTearDown(() {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // 临时目录里的过期文件，系统会自己回收
      }
    });

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
    await tester.runAsync(() async {
      await precacheImage(_smallProvider(path), host);
      // 等价于「大图在飞行期间已经解好了」：落地只该换宿主，不该再解一次
      await precacheImage(_bigProvider(path), host);
    });
    await tester.pump();
    expect(
      imageAlreadyCached(_bigProvider(path)),
      isTrue,
      reason: '前置条件：大图解码已经在缓存里',
    );
    await _reset(tester);

    // 飞行 300ms 结束那一帧
    final _Shot landed = await _midFlight(
      tester,
      path,
      backdrop: true,
      sampleAt: const Duration(milliseconds: 320),
    );
    final Rect rect = landed.coverRect();
    expect(
      landed.coverPixels(),
      greaterThan(5000),
      reason:
          '落地第一帧封面就得在：飞行层一卸载、页面那份要是被拆掉重挂再冷解码，'
          '中间露出来的就是底下的灰色阴影盘（2026-11-22 的实拍）',
    );
    expect(rect.width, closeTo(_bigSize, 2), reason: '落地就该是最终尺寸');
    expect(rect.height, closeTo(_bigSize, 2));
  });

  testWidgets('圆形封面飞行途中不能被方块垫底带歪', (WidgetTester tester) async {
    final String path = await _writePng(tester);
    addTearDown(() {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // 同上
      }
    });

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
    await tester.runAsync(() async {
      await precacheImage(_smallProvider(path), host);
    });
    await tester.pump();
    await _reset(tester);

    // 方形封面（圆角矩形）：包围盒四角里那块是实心的
    final _Shot square = await _midFlight(tester, path, backdrop: true);
    final Rect squareRect = square.coverRect();
    expect(
      square.coverPixelsIn(_Shot.cornerPatch(squareRect)),
      greaterThan(200),
      reason: '方形封面的角该是实的',
    );
    await _reset(tester);

    // 圆形封面：垫底那份也得是圆的，否则起飞的头几帧是一块方图
    // （`circular` 是「跟随设置」，测试里要先把这个开关打开）
    circularCovers.value = true;
    addTearDown(() => circularCovers.value = false);
    final _Shot round = await _midFlight(
      tester,
      path,
      backdrop: true,
      circular: true,
    );
    final Rect roundRect = round.coverRect();
    expect(
      round.coverPixelsIn(_Shot.cornerPatch(roundRect)),
      0,
      reason: '圆形封面飞行途中还是圆的：角上不能有东西',
    );
    expect(round.coverPixels(), greaterThan(5000), reason: '同时封面本体还得在');
  });
}
