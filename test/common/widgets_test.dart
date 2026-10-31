import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/common.dart';

// 组件测试：只验证渲染与回调，不触碰 Rust 接口。
Future<void> _pumpInScaffold(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

/// 1×1 透明 PNG：换封面用例只需要一个真能通过 `existsSync` 的文件
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 取当前渲染的那张封面的文件路径（`Image.file` → `ResizeImage(FileImage)`）
String _shownCoverPath(WidgetTester tester) {
  return _coverPathOf(tester.widget<Image>(find.byType(Image).first));
}

String _coverPathOf(Image image) {
  ImageProvider provider = image.image;
  if (provider is ResizeImage) {
    provider = provider.imageProvider;
  }
  return (provider as FileImage).file.path;
}

void main() {
  group('EmptyState', () {
    testWidgets('渲染图标、标题、说明与行动按钮', (WidgetTester tester) async {
      await _pumpInScaffold(
        tester,
        EmptyState(
          icon: Icons.library_music_outlined,
          title: '曲库还是空的',
          message: '在设置里添加一个音乐目录。',
          action: FilledButton(onPressed: () {}, child: const Text('去设置')),
        ),
      );

      expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
      expect(find.text('曲库还是空的'), findsOneWidget);
      expect(find.text('在设置里添加一个音乐目录。'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
    });

    testWidgets('省略说明与按钮时只渲染图标和标题', (WidgetTester tester) async {
      await _pumpInScaffold(
        tester,
        const EmptyState(icon: Icons.search_off, title: '没有匹配的曲目'),
      );

      expect(find.byIcon(Icons.search_off), findsOneWidget);
      expect(find.text('没有匹配的曲目'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('行动按钮可点击', (WidgetTester tester) async {
      int taps = 0;
      await _pumpInScaffold(
        tester,
        EmptyState(
          icon: Icons.folder_open,
          title: '还没有目录',
          action: FilledButton(
            onPressed: () => taps += 1,
            child: const Text('添加目录'),
          ),
        ),
      );

      await tester.tap(find.text('添加目录'));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('LoadingState', () {
    testWidgets('渲染进度指示器与文案', (WidgetTester tester) async {
      await _pumpInScaffold(tester, const LoadingState(message: '正在扫描…'));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在扫描…'), findsOneWidget);
    });

    testWidgets('没有文案时只渲染进度指示器', (WidgetTester tester) async {
      await _pumpInScaffold(tester, const LoadingState());

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('AlbumCover', () {
    testWidgets('没有路径或文件不存在时回退到音符图标', (WidgetTester tester) async {
      await _pumpInScaffold(tester, const AlbumCover());
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      await _pumpInScaffold(
        tester,
        const AlbumCover(path: r'Z:\definitely-missing\cover.jpg'),
      );
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('播放中回退图标换成均衡器', (WidgetTester tester) async {
      await _pumpInScaffold(tester, const AlbumCover(playing: true));
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    });

    testWidgets('封面文件存在时渲染图片', (WidgetTester tester) async {
      late Directory dir;
      late File file;
      // 真实文件 IO 在 fake async 下不会自行完成，必须放进 runAsync
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('lamp_cover');
        file = File('${dir.path}/cover.png');
        // 1×1 透明 PNG
        await file.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
            'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
          ),
        );
      });
      addTearDown(() => dir.deleteSync(recursive: true));

      await _pumpInScaffold(tester, AlbumCover(path: file.path));
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.music_note), findsNothing);
    });

    testWidgets('打开圆形封面后裁成正圆，关掉能恢复圆角方形', (WidgetTester tester) async {
      // 全局开关：用例结束必须复位，否则会污染其它用例
      addTearDown(() => circularCovers.value = false);

      await _pumpInScaffold(tester, const AlbumCover(size: 40, radius: 12));

      BorderRadius clipRadius() {
        final ClipRRect clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
        return clip.borderRadius as BorderRadius;
      }

      expect(clipRadius().topLeft.x, 12, reason: '默认还是圆角方形');
      expect(find.byType(ClipOval), findsNothing);

      circularCovers.value = true;
      await tester.pump();
      // 圆形走 ClipOval：半径跟着实际盒子走，不依赖 size
      expect(find.byType(ClipOval), findsOneWidget);
      expect(find.byType(ClipRRect), findsNothing);

      circularCovers.value = false;
      await tester.pump();
      expect(clipRadius().topLeft.x, 12);
      expect(find.byType(ClipOval), findsNothing);
    });

    testWidgets('圆形封面被 Hero 拉大后仍是正圆，不是圆角方块', (WidgetTester tester) async {
      // 复现飞行现场：Hero 把播放条那枚 56 的封面塞进「动画尺寸」的紧约束里。
      // 旧实现按 size/2=28 算圆角，盒子被拉到 340 就成了圆角方块
      addTearDown(() => circularCovers.value = false);
      circularCovers.value = true;

      await _pumpInScaffold(
        tester,
        const SizedBox(
          width: 340,
          height: 340,
          child: AlbumCover(size: 56, radius: 16),
        ),
      );

      final Finder oval = find.byType(ClipOval);
      expect(oval, findsOneWidget);
      expect(
        tester.getSize(oval),
        const Size(340, 340),
        reason: '裁剪盒子跟着动画尺寸走，而不是 56',
      );
      // 圆角矩形的半径是按 56 算的，一旦出现就说明又退回到「小半径 + 大盒子」
      expect(find.byType(ClipRRect), findsNothing);
    });

    group('换封面过渡', () {
      /// 造 [count] 张互不相同的封面文件，返回按顺序排好的路径
      Future<List<String>> makeCovers(WidgetTester tester, int count) async {
        late Directory dir;
        final List<String> paths = <String>[];
        // 真实文件 IO 在 fake async 下不会自行完成，必须放进 runAsync
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('lamp_cover_fade');
          for (int i = 0; i < count; i += 1) {
            final File file = File('${dir.path}/$i.png');
            await file.writeAsBytes(base64Decode(_onePixelPng));
            paths.add(file.path);
          }
        });
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } on FileSystemException {
            // 解码出来的图还挂在 ImageCache 上，Windows 下文件句柄没放，
            // 删不掉就留给系统清临时目录
          }
        });
        return paths;
      }

      testWidgets('关掉过渡时换路径立刻生效，旧封面不留在树上', (WidgetTester tester) async {
        final List<String> covers = await makeCovers(tester, 2);

        await _pumpInScaffold(tester, AlbumCover(path: covers[0]));
        await tester.pump();
        expect(_shownCoverPath(tester), covers[0]);

        await _pumpInScaffold(tester, AlbumCover(path: covers[1]));
        await tester.pump();

        expect(find.byType(Image), findsOneWidget);
        expect(_shownCoverPath(tester), covers[1]);
      });

      testWidgets('打开过渡后换路径：新旧两张同时在，结束后只剩新封面', (WidgetTester tester) async {
        final List<String> covers = await makeCovers(tester, 2);

        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[0], animateOnChange: true),
        );
        await tester.pump();
        expect(find.byType(Image), findsOneWidget);

        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[1], animateOnChange: true),
        );
        // 测试环境的图片解码不会自行完成，切换依赖那条 250ms 兜底定时器
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.byType(Image),
          findsNWidgets(2),
          reason: '过渡期间旧封面垫在下面，不能提前拆掉',
        );
        expect(
          tester
              .widget<Opacity>(
                find
                    .descendant(
                      of: find.byType(AlbumCover),
                      matching: find.byType(Opacity),
                    )
                    .first,
              )
              .opacity,
          lessThan(0.05),
          reason: '换图那一帧新封面还该是透明的，从半透明起步等于硬切',
        );

        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        expect(_shownCoverPath(tester), covers[1]);
      });

      testWidgets('连切时只认最后一张，中间那张不会被画出来', (WidgetTester tester) async {
        final List<String> covers = await makeCovers(tester, 3);

        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[0], animateOnChange: true),
        );
        await tester.pump();

        // 第二张还在等解码就切第三张：第一张的兜底定时器与请求一起作废
        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[1], animateOnChange: true),
        );
        await tester.pump(const Duration(milliseconds: 80));
        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[2], animateOnChange: true),
        );
        await tester.pump(const Duration(milliseconds: 300));

        // 过渡中：垫底的是第一张、淡入的是第三张；第二张从没上过屏
        expect(
          tester
              .widgetList<Image>(find.byType(Image))
              .map(_coverPathOf)
              .toList(),
          <String>[covers[0], covers[2]],
        );

        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        expect(_shownCoverPath(tester), covers[2]);
      });

      testWidgets('从没有封面切到有封面：回退图标垫底，过渡完只剩图片', (WidgetTester tester) async {
        final List<String> covers = await makeCovers(tester, 1);

        await _pumpInScaffold(tester, const AlbumCover(animateOnChange: true));
        await tester.pump();
        expect(find.byIcon(Icons.music_note), findsOneWidget);

        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[0], animateOnChange: true),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(Image), findsOneWidget);
        expect(find.byIcon(Icons.music_note), findsOneWidget);

        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.music_note), findsNothing);
        expect(find.byType(Image), findsOneWidget);
      });

      testWidgets('目标封面已在缓存里（同步回调）也不会在 build 期间 setState', (
        WidgetTester tester,
      ) async {
        final List<String> covers = await makeCovers(tester, 2);
        String path = covers[0];
        late StateSetter rebuild;

        // 必须由**父级** setState 驱动换图：pumpWidget 直接换是不在 build
        // 阶段里的，测不出「build 期间 setState」那个断言
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  rebuild = setState;
                  return AlbumCover(path: path, animateOnChange: true);
                },
              ),
            ),
          ),
        );
        await tester.pump();

        // 真解码一次，让第二张躺在 ImageCache 里：真正换歌时它就是这条路
        final BuildContext context = tester.element(find.byType(AlbumCover));
        final ImageProvider cached = ResizeImage.resizeIfNeeded(
          (MediaQuery.devicePixelRatioOf(context) * 40).round().clamp(32, 1024),
          null,
          FileImage(File(covers[1])),
        );
        await tester.runAsync(() => precacheImage(cached, context));

        rebuild(() => path = covers[1]);
        await tester.pump();

        expect(find.byType(Image), findsNWidgets(2));

        // 250ms 的兜底定时器在过渡途中还会响一次：它和已完成的解码回调
        // 指向同一张图，不能借机把过渡层撤掉（那会从半透明直接跳到终点）
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(
            of: find.byType(AlbumCover),
            matching: find.byType(Transform),
          ),
          findsOneWidget,
          reason: '兜底定时器到达时过渡还没走完，不能被打断',
        );

        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        expect(_shownCoverPath(tester), covers[1]);
      });

      testWidgets('过渡中途：新封面半透明且比原尺寸略大，收到原位才结束', (WidgetTester tester) async {
        final List<String> covers = await makeCovers(tester, 2);

        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[0], animateOnChange: true),
        );
        await tester.pump();
        await _pumpInScaffold(
          tester,
          AlbumCover(path: covers[1], animateOnChange: true),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 170));

        final Finder incoming = find.descendant(
          of: find.byType(AlbumCover),
          matching: find.byType(Opacity),
        );
        expect(
          tester.widget<Opacity>(incoming.first).opacity,
          inExclusiveRange(0.0, 1.0),
          reason: '过渡中途应该是半透明的',
        );

        final Matrix4 matrix = tester
            .widget<Transform>(
              find
                  .descendant(
                    of: find.byType(AlbumCover),
                    matching: find.byType(Transform),
                  )
                  .first,
            )
            .transform;
        expect(
          matrix.getMaxScaleOnAxis(),
          inExclusiveRange(1.0, 1.06),
          reason: '中途要还在往回收，收完正好是 1.0',
        );

        await tester.pumpAndSettle();
        // 过渡层整个撤掉，只剩一张静止的封面（缩放回到 1.0 就不再需要它）
        expect(
          find.descendant(
            of: find.byType(AlbumCover),
            matching: find.byType(Transform),
          ),
          findsNothing,
        );
        expect(find.byType(Image), findsOneWidget);
      });
    });
  });

  group('ErrorRetry', () {
    testWidgets('渲染标题与去掉前缀的错误文本，点击触发回调', (WidgetTester tester) async {
      int retries = 0;
      await _pumpInScaffold(
        tester,
        ErrorRetry(
          title: '扫描失败',
          error: Exception('目录不存在'),
          onRetry: () => retries += 1,
        ),
      );

      expect(find.text('扫描失败'), findsOneWidget);
      expect(find.text('目录不存在'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();

      expect(retries, 1);
    });

    test('describe 去掉 Exception / Error 前缀', () {
      expect(ErrorRetry.describe(Exception('曲库未初始化')), '曲库未初始化');
      // StateError 的 toString 自带 'Bad state: ' 前缀，不属于要剥掉的两类，原样保留
      expect(ErrorRetry.describe(StateError('状态异常')), 'Bad state: 状态异常');
      expect(ErrorRetry.describe('普通字符串'), '普通字符串');
    });

    test('describe 对空错误给出兜底文案', () {
      expect(ErrorRetry.describe(Exception()), '未知错误');
      expect(ErrorRetry.describe(''), '未知错误');
    });
  });

  group('AlbumCover 圆形裁剪', () {
    testWidgets('被压成中间尺寸时仍按实际尺寸裁成正圆', (WidgetTester tester) async {
      // Hero 飞行途中封面会被紧约束压到「播放条尺寸 → 播放页尺寸」之间，
      // 半径如果按 widget.size / 2 算，中途就是一个圆角方块
      circularCovers.value = true;
      addTearDown(() => circularCovers.value = false);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: AlbumCover(size: 56),
              ),
            ),
          ),
        ),
      );

      // 圆形用 ClipOval：飞行途中尺寸每帧都在变，椭圆裁剪天然跟着边界走，
      // 不需要「按实际尺寸算半径」那种每帧重建的 LayoutBuilder
      expect(
        find.descendant(
          of: find.byType(AlbumCover),
          matching: find.byType(ClipOval),
        ),
        findsOneWidget,
      );
    });

    testWidgets('方形封面仍用组件传入的圆角', (WidgetTester tester) async {
      circularCovers.value = false;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: AlbumCover(size: 56, radius: 16),
              ),
            ),
          ),
        ),
      );

      final ClipRRect clip = tester.widget<ClipRRect>(
        find
            .descendant(
              of: find.byType(AlbumCover),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(clip.borderRadius, BorderRadius.circular(16));
    });
  });
}
