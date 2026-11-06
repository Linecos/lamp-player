import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/common/widgets/cover_shape.dart';
import 'package:lamp_player/src/features/player/cover_spin.dart';
import 'package:lamp_player/src/features/player/playback_queue.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/features/player/spectrum_bars.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

const ValueKey<String> _progressKey = ValueKey<String>('player-progress');
const ValueKey<String> _volumeKey = ValueKey<String>('player-volume');

Slider _sliderOf(WidgetTester tester, Key key) {
  return tester.widget<Slider>(
    find.descendant(of: find.byKey(key), matching: find.byType(Slider)),
  );
}

/// 音量图标（静音 / 取消静音都可能，按图标找更稳）
Finder _volumeIcon() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Icon &&
      (widget.icon == Icons.volume_up ||
          widget.icon == Icons.volume_down ||
          widget.icon == Icons.volume_off),
);

/// 把 [RectTween] 的 protected `lerp` 暴露出来给测试取值
class _OpenRectTween extends RectTween {
  _OpenRectTween({required super.begin, required super.end});

  Rect lerpAt(double t) => lerp(t)!;
}

/// 鼠标移到音量图标上，把竖条浮层唤出来

/// 在 [target] 上滚动鼠标滚轮（dy < 0 表示向上滚）
Future<void> _scrollAt(WidgetTester tester, Finder target, double dy) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  final Offset center = tester.getCenter(target);
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

Future<TestGesture> _hoverVolume(WidgetTester tester) async {
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer();
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(_volumeIcon()));
  await tester.pumpAndSettle();
  return mouse;
}

Future<void> _pumpBar(
  WidgetTester tester, {
  bool isAvailable = true,
  bool isPlaying = false,
  bool canSeek = true,
  Track? track,
  double position = 0,
  double duration = 200,
  double volume = 1,
  double width = 1280,
  ValueChanged<double>? onSeekStart,
  ValueChanged<double>? onSeekChanged,
  ValueChanged<double>? onSeekEnd,
  ValueChanged<double>? onVolumeChanged,
  VoidCallback? onToggleMute,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onShowQueue,
  VoidCallback? onCyclePlayMode,
  LoopMode repeat = LoopMode.off,
  bool shuffle = false,
  VoidCallback? onOpenNowPlaying,
  ValueListenable<List<double>>? spectrum,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.defaultSeed),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: PlayerBar(
            track: track,
            isPlaying: isPlaying,
            isAvailable: isAvailable,
            canSeek: canSeek,
            position: position,
            duration: duration,
            volume: volume,
            onSeekStart: onSeekStart,
            onSeekChanged: onSeekChanged,
            onSeekEnd: onSeekEnd,
            onVolumeChanged: onVolumeChanged,
            onToggleMute: onToggleMute,
            onPrevious: onPrevious,
            onNext: onNext,
            onShowQueue: onShowQueue,
            onCyclePlayMode: onCyclePlayMode,
            repeat: repeat,
            shuffle: shuffle,
            onOpenNowPlaying: onOpenNowPlaying,
            spectrum: spectrum,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('拖动进度条：开始、预览、松手各回调一次', (WidgetTester tester) async {
    final List<double> starts = <double>[];
    final List<double> previews = <double>[];
    final List<double> ends = <double>[];

    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      duration: 200,
      onSeekStart: starts.add,
      onSeekChanged: previews.add,
      onSeekEnd: ends.add,
    );

    await tester.drag(find.byKey(_progressKey), const Offset(140, 0));
    await tester.pump();

    expect(starts, hasLength(1));
    expect(previews, isNotEmpty);
    expect(ends, hasLength(1));
    expect(ends.single, greaterThan(0));
    expect(ends.single, lessThanOrEqualTo(200));
  });

  testWidgets('拖动过程中时间标签跟随预览位置', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      position: 0,
      duration: 200,
    );

    expect(find.text('00:00'), findsOneWidget);

    // 父级把预览位置回灌给 position 后，标签应立刻更新
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      position: 100,
      duration: 200,
    );

    expect(find.text('01:40'), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
  });

  testWidgets('音量滚轮向上滚加 10%', (WidgetTester tester) async {
    final List<double> volumes = <double>[];
    await _pumpBar(tester, volume: 0.5, onVolumeChanged: volumes.add);

    await _hoverVolume(tester);
    await _scrollAt(tester, find.byKey(_volumeKey), -40);

    expect(volumes.single, closeTo(0.6, 0.001));
  });

  testWidgets('音量滚轮向下滚减 10%', (WidgetTester tester) async {
    final List<double> volumes = <double>[];
    await _pumpBar(tester, volume: 0.5, onVolumeChanged: volumes.add);

    await _hoverVolume(tester);
    await _scrollAt(tester, find.byKey(_volumeKey), 40);

    expect(volumes.single, closeTo(0.4, 0.001));
  });

  testWidgets('音量滚轮到顶夹在 1.0', (WidgetTester tester) async {
    final List<double> volumes = <double>[];
    await _pumpBar(tester, volume: 0.95, onVolumeChanged: volumes.add);

    await _hoverVolume(tester);
    await _scrollAt(tester, find.byKey(_volumeKey), -40);

    expect(volumes.single, closeTo(1.0, 0.001), reason: '不越界，也不发 1.05');
  });

  testWidgets('音量滑块变化会回调 0~1 的值', (WidgetTester tester) async {
    final List<double> volumes = <double>[];

    await _pumpBar(tester, volume: 0.5, onVolumeChanged: volumes.add);

    await _hoverVolume(tester);
    // 竖条：往上拖是调大（RotatedBox 把横条转成 90°，右端在上）
    await tester.drag(find.byKey(_volumeKey), const Offset(0, -30));
    await tester.pump();

    expect(volumes, isNotEmpty);
    expect(volumes.last, inInclusiveRange(0.0, 1.0));
    expect(volumes.last, greaterThan(0.5));
  });

  testWidgets('引擎不可用时进度与音量滑块都禁用', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      isAvailable: false,
      track: sampleTrack(title: '夜航'),
      onSeekEnd: (_) {},
      onVolumeChanged: (_) {},
    );

    // 引擎不可用时音量浮层根本不弹，且图标禁用
    await _hoverVolume(tester);
    expect(find.byKey(_volumeKey), findsNothing);
    final IconButton icon = tester.widget<IconButton>(
      find.ancestor(of: _volumeIcon(), matching: find.byType(IconButton)).first,
    );
    expect(icon.onPressed, isNull, reason: '引擎不可用时静音按钮也要禁用');
    expect(_sliderOf(tester, _progressKey).onChanged, isNull);
  });

  testWidgets('没有当前曲目时进度滑块禁用但音量可调', (WidgetTester tester) async {
    await _pumpBar(tester, onVolumeChanged: (_) {});

    expect(_sliderOf(tester, _progressKey).onChanged, isNull);
    await _hoverVolume(tester);
    expect(_sliderOf(tester, _volumeKey).onChanged, isNotNull);
  });

  testWidgets('音量图标随音量变化，点击触发静音回调', (WidgetTester tester) async {
    await _pumpBar(tester, volume: 0);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await _pumpBar(tester, volume: 0.2);
    expect(find.byIcon(Icons.volume_down), findsOneWidget);

    int toggles = 0;
    await _pumpBar(tester, volume: 0.9, onToggleMute: () => toggles += 1);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('静音状态下的按钮提示为取消静音', (WidgetTester tester) async {
    await _pumpBar(tester, volume: 0, onToggleMute: () {});

    expect(find.byTooltip('取消静音'), findsOneWidget);
    expect(find.byTooltip('静音'), findsNothing);
  });

  testWidgets('停止态（canSeek=false）禁用进度拖动', (WidgetTester tester) async {
    final List<double> ends = <double>[];
    await _pumpBar(
      tester,
      isPlaying: false,
      canSeek: false,
      track: sampleTrack(title: '夜航'),
      position: 30,
      duration: 180,
      onSeekEnd: ends.add,
    );

    expect(_sliderOf(tester, _progressKey).onChanged, isNull);
    await tester.drag(find.byKey(_progressKey), const Offset(120, 0));
    await tester.pump();
    expect(ends, isEmpty, reason: '停止态不应触发 seek');
  });

  testWidgets('上一首 / 下一首 / 队列 / 播放模式按钮转发回调', (WidgetTester tester) async {
    int previous = 0;
    int next = 0;
    int queue = 0;
    int mode = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      repeat: LoopMode.all,
      onPrevious: () => previous += 1,
      onNext: () => next += 1,
      onShowQueue: () => queue += 1,
      onCyclePlayMode: () => mode += 1,
    );

    await tester.tap(find.byTooltip('上一首 (Ctrl+←)'));
    await tester.tap(find.byTooltip('下一首 (Ctrl+→)'));
    await tester.tap(find.byTooltip('播放队列'));
    await tester.tap(find.byTooltip('播放模式：列表循环'));
    await tester.pump();

    expect(previous, 1);
    expect(next, 1);
    expect(queue, 1);
    expect(mode, 1);
    expect(find.byType(Badge), findsNothing, reason: '队列按钮不再显示数量角标');
  });

  testWidgets('播放条用 AlbumCover 渲染当前曲目封面', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航', coverPath: '/missing/cover.jpg'),
    );

    expect(find.byType(AlbumCover), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget, reason: '文件不存在时回退');
  });

  testWidgets('没有当前曲目时上一首 / 下一首 / 暂停都禁用', (WidgetTester tester) async {
    await _pumpBar(tester, onPrevious: () {}, onNext: () {});

    IconButton buttonWithIcon(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    expect(buttonWithIcon(Icons.skip_previous).onPressed, isNull);
    expect(buttonWithIcon(Icons.skip_next).onPressed, isNull);
    // 播放/暂停键是手写的 InkWell（要挂长按），禁用态看 onTap
    expect(
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey<String>('player-play-pause')),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('封面可点打开正在播放页，墨水层不被底色遮住', (WidgetTester tester) async {
    int opens = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      onOpenNowPlaying: () => opens += 1,
    );

    final Finder cover = find.byKey(
      const ValueKey<String>('player-bar-open-now-playing'),
    );
    expect(tester.widget<InkWell>(cover).hoverColor, isNotNull);

    // 封面挂着 Hero：打开正在播放页时从这里飞大，返回时飞回来
    final Hero hero = tester.widget<Hero>(
      find.ancestor(of: find.byType(AlbumCover), matching: find.byType(Hero)),
    );
    expect(hero.tag, coverHeroTag);

    // 占位要**继续挂着原封面**：飞行期间两端都被换成占位，图片订阅断了的话，
    // 落地时若这张尺寸已被缓存淘汰就会先空一帧（收起播放页时「封面闪一下」）。
    // 但占位里不能包 `Opacity`：Impeller 会把透明度下推给绘制内容，碰到底层
    // 带模糊的直接断言失败并逐帧退回 saveLayer。`Offstage` 不布局不绘制，
    // 子树与订阅都还在。
    expect(hero.placeholderBuilder, isNotNull);
    const Widget probe = SizedBox(width: 8, height: 8);
    final Widget placeholder = hero.placeholderBuilder!(
      tester.element(find.byType(AlbumCover)),
      const Size(56, 56),
      probe,
    );
    expect(placeholder, isNot(isA<Opacity>()));
    expect(
      (placeholder as SizedBox).child,
      isA<Offstage>(),
      reason: '占位用 Offstage 挂住封面，而不是换成一无所有的空白',
    );
    expect((placeholder.child! as Offstage).child, same(probe));

    // Hero 外面要有绘制边界：起飞 / 落地把占位换回封面时，脏区只到这一小块，
    // 不会把整个播放条拖着重画
    expect(
      find.ancestor(
        of: find.byType(Hero),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );

    // 飞行插值要全程保持正方形。实际飞行是「播放条（左下 56²）→ 播放页封面
    // （右上 340²）」，位置与尺寸同时差一个量级；`MaterialRectArcTween` 是
    // 四个角各走各的弧线，位置差一大宽高速度就错开，实测中途会变成 276×172
    // 的横长条。lerp 是 protected，包一层子类来取值
    final Tween<Rect?> raw = hero.createRectTween!(
      const Rect.fromLTWH(40, 600, 56, 56),
      const Rect.fromLTWH(500, 80, 340, 340),
    );
    for (final double t in const <double>[0.25, 0.5, 0.75]) {
      final Rect mid = _OpenRectTween(
        begin: raw.begin!,
        end: raw.end!,
      ).lerpAt(t);
      expect(
        (mid.width - mid.height).abs(),
        lessThan(0.5),
        reason: 't=$t 时宽 ${mid.width} 高 ${mid.height}，飞行中不能变形',
      );
      expect(mid.width, greaterThan(56), reason: '尺寸要单调变大');
      expect(mid.width, lessThan(340), reason: '尺寸要单调变大');
    }

    final Material surface = tester.widget<Material>(
      find.ancestor(of: cover, matching: find.byType(Material)).first,
    );
    expect(
      surface.type,
      MaterialType.transparency,
      reason: '播放条底色画在 Container 上，需要一个透明 Material 托住墨水',
    );

    await tester.tap(cover);
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('圆形封面时播放条小封面跟着同一相位转', (WidgetTester tester) async {
    addTearDown(() => circularCovers.value = false);
    CoverSpin.reset();
    addTearDown(CoverSpin.reset);

    await _pumpBar(tester, track: sampleTrack(title: '夜航'), isPlaying: true);
    expect(
      find.byKey(const ValueKey<String>('spinning-cover')),
      findsNothing,
      reason: '方形封面不转',
    );

    circularCovers.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    final Transform spin = tester.widget<Transform>(
      find.byKey(const ValueKey<String>('spinning-cover')),
    );
    final List<double> m = spin.transform.storage;
    final double turns = math.atan2(m[1], m[0]) / (2 * math.pi);
    // 5 秒 / 25 秒一圈；播放条与大封面共用同一份相位，Hero 落地才不会跳一下
    expect(turns, closeTo(5 / 25, 0.02));
  });

  testWidgets('曲名区域也可点打开正在播放页', (WidgetTester tester) async {
    int opens = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      onOpenNowPlaying: () => opens += 1,
    );

    final Finder titleArea = find.byKey(
      const ValueKey<String>('player-bar-open-now-playing-title'),
    );
    expect(tester.widget<InkWell>(titleArea).hoverColor, isNotNull);

    await tester.tap(find.descendant(of: titleArea, matching: find.text('夜航')));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('整条播放条的空白处都能打开正在播放页', (WidgetTester tester) async {
    int opens = 0;
    int nexts = 0;
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      onNext: () => nexts += 1,
      onOpenNowPlaying: () => opens += 1,
    );

    final Finder area = find.byKey(
      const ValueKey<String>('player-bar-open-anywhere'),
    );
    expect(area, findsOneWidget);

    final Rect box = tester.getRect(area);
    final Rect slider = tester.getRect(find.byKey(_progressKey));

    // 三处原本点不动的空白，从左到右覆盖整条：
    // 左段歌词区、右段进度条上方的空隙、卡片右边缘的 14px 内边距
    final List<Offset> blanks = <Offset>[
      Offset(box.left + box.width * 0.36, box.center.dy),
      Offset(slider.center.dx, box.top + 6),
      Offset(box.right - 3, box.center.dy),
    ];
    for (final Offset spot in blanks) {
      await tester.tapAt(spot);
      await tester.pump();
    }
    expect(opens, blanks.length, reason: '左段留白、右段缝隙、内边距都应能打开');

    // 按钮本身不被外层抢走：点「下一首」只切歌，不打开播放页
    await tester.tap(find.byIcon(Icons.skip_next));
    await tester.pump();
    expect(nexts, 1);
    expect(opens, blanks.length, reason: '点按钮不应顺带打开正在播放页');
  });

  testWidgets('三键落在播放条中轴上', (WidgetTester tester) async {
    // 宽窗口和最小窗口（900 + 侧栏展开 → 618）都要居中
    for (final double width in <double>[1280, 618]) {
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        width: width,
      );

      // 左段与右段等宽，播放键就落在整条播放条的中轴上
      final double center = tester.getCenter(find.byType(PlayerBar)).dx;
      final double play = tester
          .getCenter(find.byKey(const ValueKey<String>('player-play-pause')))
          .dx;
      expect(play, closeTo(center, 1), reason: '宽度 $width 下三键偏了');
    }
  });

  testWidgets('窄窗口不挤爆：模式与队列仍各占一个按钮，音量不占位', (WidgetTester tester) async {
    // 900 宽窗口 + 侧栏展开时，播放条可用宽度就是 618
    await _pumpBar(tester, track: sampleTrack(title: '夜航'), width: 618);

    expect(tester.takeException(), isNull, reason: '窄窗口不允许溢出');
    expect(find.byTooltip('播放模式：顺序播放'), findsOneWidget);
    expect(find.byTooltip('播放队列'), findsOneWidget);
    expect(find.byTooltip('静音'), findsOneWidget);
    expect(find.byKey(_volumeKey), findsNothing, reason: '音量条悬停才出现');
    // 测试字体每个字符都按字号宽度渲染，时间标签比真实字体宽近一倍；这里
    // 47.5 对应真实字体约 95px，够拖。切回两个按钮后右侧更挤，下限相应放宽。
    expect(
      tester.getSize(find.byKey(_progressKey)).width,
      greaterThan(40),
      reason: '进度条在窄窗口也要有可用宽度',
    );
  });

  testWidgets('中等宽度：两个按钮都在，悬停静音图标才弹出竖条', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      track: sampleTrack(title: '夜航'),
      width: 800,
      onVolumeChanged: (_) {},
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('播放模式：顺序播放'), findsOneWidget);
    expect(find.byTooltip('播放队列'), findsOneWidget);
    expect(find.byKey(_volumeKey), findsNothing);

    final TestGesture mouse = await _hoverVolume(tester);

    expect(find.byKey(_volumeKey), findsOneWidget, reason: '悬停后弹出竖条');
    final Rect slider = tester.getRect(find.byKey(_volumeKey));
    expect(slider.height, greaterThan(slider.width), reason: '竖着的才是竖条');

    // 移开指针后收起
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(_volumeKey), findsNothing);
  });

  testWidgets('宽窗口下模式与队列按钮显示', (WidgetTester tester) async {
    await _pumpBar(tester, track: sampleTrack(title: '夜航'));

    expect(find.byTooltip('播放模式：顺序播放'), findsOneWidget);
    expect(find.byTooltip('播放队列'), findsOneWidget);
    expect(find.byKey(_volumeKey), findsNothing, reason: '音量条常驻已去掉');
    expect(
      tester.getSize(find.byKey(_progressKey)).width,
      greaterThan(120),
      reason: '默认窗口下进度条要够长',
    );
  });

  testWidgets('比窗口下限还窄时也不溢出（兜底）', (WidgetTester tester) async {
    // 真实窗口最小 900（侧栏展开时播放条 618），这里只验证布局算式在更窄的
    // 宽度下也不会让 Row 溢出
    await _pumpBar(tester, track: sampleTrack(title: '夜航'), width: 420);

    expect(tester.takeException(), isNull);
  });

  group('播放条频谱', () {
    // 左段在 1280 窗口约 554、900 + 侧栏展开时约 223：前者放得下频谱，
    // 后者只够曲名
    testWidgets('宽窗口下频谱接在曲名右侧，占满腾出的那块', (WidgetTester tester) async {
      final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
        List<double>.generate(24, (int i) => 0.3 + (i % 5) * 0.1),
      );
      addTearDown(bands.dispose);

      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        spectrum: bands,
      );

      final Finder spectrum = find.byKey(_spectrumKey);
      expect(spectrum, findsOneWidget);
      // 歌词预览已经去掉，这块位置只留给频谱
      expect(
        find.byKey(const ValueKey<String>('player-bar-lyric')),
        findsNothing,
      );

      final Rect bars = tester.getRect(spectrum);
      final Rect title = tester.getRect(
        find.byKey(const ValueKey<String>('player-bar-open-now-playing-title')),
      );
      expect(bars.center.dx, greaterThan(title.center.dx), reason: '频谱在曲名右侧');
      expect(bars.height, 24);
      expect(
        bars.width,
        greaterThan(150),
        reason: '要占满空出来的那半块，而不是原来 46px 的小窄条',
      );
      expect(
        tester.widget<SpectrumBars>(spectrum).stretch,
        isTrue,
        reason: '铺满模式：柱子按可用宽度均分，24 段全用上',
      );

      // 两侧留白要相当：左边距 = 曲名文字到频谱，右边距 = 频谱到三键。
      // 按固定对半分的时候频谱被顶到右缘（左 170 / 右 25），看着像贴着
      // 播放键，这条就是防它回去
      final Rect prev = tester.getRect(
        find.ancestor(
          of: find.byIcon(Icons.skip_previous),
          matching: find.byType(IconButton),
        ),
      );
      final double leftGap = bars.left - title.right;
      final double rightGap = prev.left - bars.right;
      expect(
        (leftGap - rightGap).abs(),
        lessThan(20),
        reason: '左 $leftGap / 右 $rightGap，频谱要在空白里居中',
      );
    });

    testWidgets('窄窗口不画频谱，曲名占满整块', (WidgetTester tester) async {
      final ValueNotifier<List<double>> bands = ValueNotifier<List<double>>(
        List<double>.filled(24, 0.5),
      );
      addTearDown(bands.dispose);

      // 900 窗口 + 侧栏展开：播放条约 618，左段只剩两百多
      await _pumpBar(
        tester,
        track: sampleTrack(title: '夜航'),
        width: 618,
        spectrum: bands,
      );

      expect(find.byKey(_spectrumKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有频谱数据源时不占位', (WidgetTester tester) async {
      await _pumpBar(tester, track: sampleTrack(title: '夜航'));

      expect(find.byKey(_spectrumKey), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('player-bar-spectrum')),
        findsNothing,
      );
    });
  });
}

const ValueKey<String> _spectrumKey = ValueKey<String>('player-bar-spectrum');
