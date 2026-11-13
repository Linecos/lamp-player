import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lamp_player/src/common/widgets/album_cover.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/features/library/widgets/cover_flight.dart';
import 'package:lamp_player/src/features/library/widgets/library_rail.dart';
import 'package:lamp_player/src/features/library/widgets/playlist_grid.dart';
import 'package:lamp_player/src/features/library/widgets/track_list_view.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

/// 歌单详情整棵子树：列表与详情共用一个分区，靠 key 区分。
Finder _playlistDetail() => find.byWidgetPredicate(
  (Widget widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('playlist-detail-'),
);

/// 分区里的「详情」子树（key 前缀区分专辑 / 艺术家 / 歌单）
Finder _detailWithPrefix(String prefix) => find.byWidgetPredicate(
  (Widget widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

Future<void> _openSection(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(LibraryRail), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('歌单封面取最新加入那首歌的封面', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(
          title: '夜航',
          path: '/music/夜航.mp3',
          coverPath: '/covers/a.jpg',
        ),
        sampleTrack(
          title: '潮汐',
          path: '/music/潮汐.mp3',
          coverPath: '/covers/b.jpg',
        ),
      ],
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/夜航.mp3');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/潮汐.mp3');
      },
    );
    await openPlaylists(tester);

    final Finder cover = find.descendant(
      of: find.byType(PlaylistGridView),
      matching: find.byType(AlbumCover),
    );
    expect(cover, findsOneWidget, reason: '有封面时不该再显示歌单图标占位');
    expect(
      tester.widget<AlbumCover>(cover).path,
      '/covers/b.jpg',
      reason: '取最新加入的那首（潮汐）的封面',
    );
  });

  testWidgets('歌单列表与详情之间有淡入上滑的过场', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('晨间');
      },
    );
    await openPlaylists(tester);

    final Finder list = find.byKey(const ValueKey<String>('playlists-list'));
    final Finder detail = find.byWidgetPredicate(
      (Widget widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'playlist-detail-',
          ),
    );
    expect(list, findsOneWidget);
    expect(detail, findsNothing);

    await tester.tap(find.text('晨间'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // 过渡中两份子树共存：旧的淡出、新的淡入
    expect(list, findsOneWidget, reason: '淡出的列表还在');
    expect(detail, findsOneWidget, reason: '淡入的详情已经进来');

    await tester.pumpAndSettle();
    expect(list, findsNothing, reason: '过渡结束只剩详情，不常驻两份');
    expect(detail, findsOneWidget);
  });

  testWidgets('专辑列表与详情之间有淡入上滑的过场', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _openSection(tester, '专辑');

    final Finder list = find.byKey(const ValueKey<String>('albums-list'));
    final Finder detail = _detailWithPrefix('albums-detail-');
    expect(list, findsOneWidget);
    expect(detail, findsNothing);

    await tester.tap(find.text('夜之专辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // 过渡中两份子树共存：旧的淡出、新的淡入
    expect(list, findsOneWidget, reason: '淡出的列表还在');
    expect(detail, findsOneWidget, reason: '淡入的详情已经进来');

    await tester.pumpAndSettle();
    expect(list, findsNothing, reason: '过渡结束只剩详情，不常驻两份');
    expect(detail, findsOneWidget);
  });

  testWidgets('艺术家列表与详情之间有淡入上滑的过场', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await _openSection(tester, '艺术家');

    final Finder list = find.byKey(const ValueKey<String>('artists-list'));
    final Finder detail = _detailWithPrefix('artists-detail-');
    expect(list, findsOneWidget);
    expect(detail, findsNothing);

    await tester.tap(find.text('林间电台').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(list, findsOneWidget, reason: '淡出的列表还在');
    expect(detail, findsOneWidget, reason: '淡入的详情已经进来');

    await tester.pumpAndSettle();
    expect(list, findsNothing, reason: '过渡结束只剩详情，不常驻两份');
    expect(detail, findsOneWidget);
  });

  testWidgets('离开歌单详情再点侧栏「歌单」，直接回到列表，不先闪之前的详情', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.createPlaylist('晨间');
      },
    );
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();
    expect(_playlistDetail(), findsOneWidget);

    // 切到音乐分区待一会儿，歌单分区被 Offstage 藏起来
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('音乐')),
    );
    await tester.pumpAndSettle();
    expect(_playlistDetail(), findsNothing);

    // 点回歌单：切换那一帧就该是列表，不能拿「详情」的旧快照顶着
    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('歌单')),
    );
    await tester.pump();
    await tester.pump();

    expect(_playlistDetail(), findsNothing, reason: '切分区已经清掉选中，旧快照里的详情不该再露一帧');
    expect(
      find.byKey(const ValueKey<String>('playlists-list')),
      findsOneWidget,
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('playlists-list')),
      findsOneWidget,
    );
    expect(_playlistDetail(), findsNothing);
  });

  testWidgets('离开专辑详情再点侧栏「专辑」，直接回到列表', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    final Finder grid = find.byKey(const PageStorageKey<String>('grid:albums'));
    Future<void> openAlbums() async {
      await tester.tap(
        find.descendant(
          of: find.byType(LibraryRail),
          matching: find.text('专辑'),
        ),
      );
      await tester.pumpAndSettle();
    }

    await openAlbums();
    await tester.tap(find.text('夜之专辑'));
    await tester.pumpAndSettle();
    expect(grid, findsNothing, reason: '已经进了专辑详情');
    expect(find.text('播放全部'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(LibraryRail), matching: find.text('音乐')),
    );
    await tester.pumpAndSettle();

    await openAlbums();
    await tester.pump();
    await tester.pump();

    expect(grid, findsOneWidget, reason: '切回来就是列表，不该先露一下之前的详情');
    expect(find.text('播放全部'), findsNothing);
  });

  testWidgets('歌单详情头部也显示封面', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(
          title: '夜航',
          path: '/music/夜航.mp3',
          coverPath: '/covers/a.jpg',
        ),
      ],
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/夜航.mp3');
      },
    );
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    // 列表行自己也有小封面，按尺寸挑头部那张（360 是详情页头部那一档）
    final Finder header = find.byWidgetPredicate(
      (Widget widget) => widget is AlbumCover && widget.size == detailCoverSize,
    );
    expect(header, findsOneWidget, reason: '详情头部应该显示封面，而不是歌单图标占位');
    expect(tester.widget<AlbumCover>(header).path, '/covers/a.jpg');
  });

  testWidgets('进专辑详情时封面飞过去，落地前详情那张先藏着', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
    );
    await _openSection(tester, '专辑');

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 详情头部那张（240 的大图）必须先藏着，否则同一张封面会一分为二；
    // 列表那张此刻正随列表淡出，是切换前的旧子树、不会重建，所以不参与判断
    for (final Element element in find.byType(CoverFlightTarget).evaluate()) {
      final RenderBox box = element.renderObject! as RenderBox;
      if (box.size.width < 200) {
        continue;
      }
      expect(
        (element.widget as CoverFlightTarget).hidden,
        isTrue,
        reason: '飞行期间详情封面要先藏着',
      );
    }

    await tester.pumpAndSettle();
    expect(
      tester.widget<CoverFlightTarget>(find.byType(CoverFlightTarget)).hidden,
      isFalse,
      reason: '落地后详情封面必须显示出来',
    );
  });

  testWidgets('封面飞行的终点跟着详情上浮，落地不跳', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
    );
    await _openSection(tester, '专辑');

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final Finder flight = find.byKey(const ValueKey<String>('cover-flight'));
    final Finder target = find.byType(CoverFlightTarget);
    expect(flight, findsOneWidget);

    // 逐帧推进到飞行尾段。必须一帧一帧走：一次性 pump 一大段会让「量终点」
    // 读到的位置落后整整一大段动画，测出来的是假跳变（真实运行是 60fps）。
    Offset flying = tester.getCenter(flight);
    for (int i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (flight.evaluate().isEmpty) {
        break;
      }
      flying = tester.getCenter(flight);
    }

    await tester.pumpAndSettle();
    expect(flight, findsNothing);
    expect(
      (flying - tester.getCenter(target)).distance,
      lessThan(2),
      reason: '飞行落点要和真实封面对上，否则落地瞬间会跳一下',
    );
  });

  testWidgets('退回列表时封面按原路飞回去', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
    );
    await _openSection(tester, '专辑');

    // 进详情之前先记下卡片封面在哪：退回时的飞行落点就是这里
    final Rect card = tester.getRect(find.byType(CoverFlightTarget));

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final Finder flight = find.byKey(const ValueKey<String>('cover-flight'));
    expect(flight, findsOneWidget, reason: '退回列表也要有飞行层');
    // 卡片那张先藏着，落地再显形（详情头部是正在淡出的旧子树，不再重建）
    for (final Element element in find.byType(CoverFlightTarget).evaluate()) {
      final RenderBox box = element.renderObject! as RenderBox;
      if (box.size.width > 200) {
        continue;
      }
      expect(
        (element.widget as CoverFlightTarget).hidden,
        isTrue,
        reason: '飞行期间卡片封面要先藏着',
      );
    }

    // 逐帧走到尾段，落点应当落在卡片原来的位置
    Offset flying = tester.getCenter(flight);
    for (int i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (flight.evaluate().isEmpty) {
        break;
      }
      flying = tester.getCenter(flight);
    }
    await tester.pumpAndSettle();
    expect(flight, findsNothing);
    expect(
      (flying - card.center).distance,
      lessThan(2),
      reason: '飞回卡片那一格，不要在半空消失',
    );
    expect(
      tester.widget<CoverFlightTarget>(find.byType(CoverFlightTarget)).hidden,
      isFalse,
      reason: '落地后卡片封面要显示出来',
    );
  });

  testWidgets('退回列表时头像字号跟盒子同比例缩放', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
    );
    await _openSection(tester, '艺术家');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('artists-list')),
        matching: find.text('林间电台'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    // 第二帧才把飞行层插进来，此刻动画 t=0
    await tester.pump();

    final Finder flight = find.byKey(const ValueKey<String>('cover-flight'));
    // 取矩阵的 x 缩放分量：`getMaxScaleOnAxis` 会被 z 轴的 1 吃掉，
    // 小于 1 的缩放它一律返回 1
    final double scale = tester.widget<Transform>(flight).transform.storage[0];
    final Text initials = tester.widget<Text>(
      find.descendant(of: flight, matching: find.byType(Text)),
    );

    // 视觉字号 = 字号 × 缩放。起点必须正好是详情头像那一档（240 × 0.22）：
    // 以前飞行层被塞进卡片大小的盒子、再放大 1.39 倍，字会先暴涨一大截
    expect(
      initials.style!.fontSize! * scale,
      closeTo(240 * 0.22, 0.5),
      reason: '起飞那一刻的字号要和详情头像一致，不能先突变',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('退回列表时封面圆角按视觉值过渡', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
    );
    await _openSection(tester, '专辑');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump();

    final Finder flight = find.byKey(const ValueKey<String>('cover-flight'));
    final Finder coverFinder = find.descendant(
      of: flight,
      matching: find.byType(AlbumCover),
    );
    final double startScale = tester
        .widget<Transform>(flight)
        .transform
        .storage[0];
    final AlbumCover start = tester.widget<AlbumCover>(coverFinder);

    // 飞行层按两端较大的尺寸（详情 240）构建，靠缩放显示；
    // 圆角传的是「视觉值 ÷ 缩放」，所以屏幕上的圆角应当就是详情那一档
    expect(start.size, closeTo(240, 0.5), reason: '飞行盒子要按大的一端构建');
    expect(startScale, closeTo(1, 0.01), reason: '起点不能先放大一下');
    expect(
      start.radius * startScale,
      closeTo(albumDetailCoverRadius, 1),
      reason: '起飞时圆角要和详情封面一致',
    );

    // 走到尾段：视觉尺寸回到卡片那档，圆角也回到卡片的圆角
    for (int i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (flight.evaluate().isEmpty) {
        break;
      }
    }
    final double endScale = tester
        .widget<Transform>(flight)
        .transform
        .storage[0];
    final AlbumCover end = tester.widget<AlbumCover>(coverFinder);
    expect(
      end.radius * endScale,
      closeTo(albumCardCoverRadius, 1),
      reason: '落地前圆角要收到卡片的 20，否则最后一下四角会突然被填上',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('飞行层只在卡片被视口切掉时才套遮罩', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        // 够多才滚得动：太少的话网格撑不满视口，拖不动
        for (int i = 0; i < 24; i += 1)
          sampleTrack(
            title: '夜航 $i',
            album: '夜之专辑 $i',
            path: '/music/夜航$i.mp3',
          ),
      ],
    );
    await _openSection(tester, '专辑');

    final Finder cover = find.byKey(const ValueKey<String>('cover-flight'));
    Finder mask() =>
        find.ancestor(of: cover, matching: find.byType(ShaderMask));

    // 1) 完全可见的卡片：照常飞，**不套遮罩**。
    //    以前这里错把「详情头部那张」（本来就在列表视口上方）当成被挡住，
    //    结果每张卡飞行最后 35% 都被压暗一截，看着就是上面一块灰的在闪
    await tester.tap(find.text('夜之专辑 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(cover, findsOneWidget);
    expect(mask(), findsNothing, reason: '卡片没被切掉，不该有遮罩（详情那张不受列表视口裁剪）');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    // 2) 滚上去一截让卡片被切掉一条边：还是要飞，但被切的那截要渐显
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('夜之专辑 0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(cover, findsOneWidget, reason: '半遮的卡片照飞');
    expect(mask(), findsOneWidget, reason: '被切掉的那一截要快速渐显');
    await tester.pumpAndSettle();
  });

  testWidgets('音乐分区的多选按钮与播放全部同行同高', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    final Finder toggle = find.byKey(
      const ValueKey<String>('library-selection-toggle'),
    );
    final Finder playAll = find.text('播放全部');
    expect(toggle, findsOneWidget, reason: '多选长在分区头部，不再挂顶栏');

    final Rect toggleRect = tester.getRect(toggle);
    // 比的是按钮本身，不是里面那行文字
    final Rect playAllRect = tester.getRect(
      find.ancestor(of: playAll, matching: find.byType(FilledButton)),
    );
    expect(toggleRect.left, greaterThan(playAllRect.left));
    expect(
      (toggleRect.center.dy - playAllRect.center.dy).abs(),
      lessThan(2),
      reason: '同一行',
    );
    expect(
      toggleRect.height,
      closeTo(playAllRect.height, 0.5),
      reason: '高度要和「播放全部」一致，不能一高一矮',
    );
  });

  testWidgets('详情页的多选按钮跟在「播放全部」右边', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
    );
    await _openSection(tester, '专辑');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();

    final Finder toggle = find.byKey(
      const ValueKey<String>('library-selection-toggle'),
    );
    final Finder playAll = find.text('播放全部');
    // 只出现一次：标题行那份要让位，否则同 key 两个 widget
    expect(toggle, findsOneWidget);

    final Rect toggleRect = tester.getRect(toggle);
    final Rect playAllRect = tester.getRect(playAll);
    expect(
      toggleRect.left,
      greaterThan(playAllRect.left),
      reason: '多选应当排在「播放全部」右边',
    );
    expect(
      (toggleRect.center.dy - playAllRect.center.dy).abs(),
      lessThan(8),
      reason: '同一行，别掉到下面去',
    );
  });

  testWidgets('Esc 从专辑 / 艺术家 / 歌单详情退回列表', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
      ],
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/夜航.mp3');
      },
    );

    // 专辑
    await _openSection(tester, '专辑');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_detailWithPrefix('albums-detail-'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('albums-list')),
      findsOneWidget,
      reason: 'Esc 退回专辑列表',
    );

    // 艺术家
    await _openSection(tester, '艺术家');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('artists-list')),
        matching: find.text('林间电台'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_detailWithPrefix('artists-detail-'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('artists-list')), findsOneWidget);

    // 歌单
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();
    expect(_playlistDetail(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_playlistDetail(), findsNothing, reason: 'Esc 退回歌单列表');
  });

  testWidgets('专辑详情默认按标题升序，改成时长排序后顺序变化', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        // 音轨号 1 在前、时长较短；标题字母序是 A → B
        sampleTrack(
          title: 'B 曲',
          album: '夜之专辑',
          path: '/music/b.mp3',
          trackNum: 1,
          durationSecs: 120,
        ),
        sampleTrack(
          title: 'A 曲',
          album: '夜之专辑',
          path: '/music/a.mp3',
          trackNum: 2,
          durationSecs: 300,
        ),
      ],
    );
    await _openSection(tester, '专辑');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();

    double topOf(String title) => tester.getTopLeft(find.text(title)).dy;
    final Finder sort = find.byKey(
      const ValueKey<String>('library-sort-album-detail'),
    );
    final Finder label = find.byKey(
      const ValueKey<String>('library-sort-album-detail-label'),
    );

    // 默认标题 A→Z：专辑 / 艺术家详情没有「原序」这一项
    expect(tester.widget<Text>(label).data, '标题');
    expect(topOf('A 曲'), lessThan(topOf('B 曲')));

    // 换成时长：B（120s）排到 A（300s）前面
    await tester.tap(sort);
    await tester.pumpAndSettle();
    expect(find.text('自定义'), findsNothing, reason: '这里不该有「自定义」');
    await tester.tap(find.text('时长').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(label).data, '时长');
    expect(topOf('B 曲'), lessThan(topOf('A 曲')));

    // 切回标题
    await tester.tap(sort);
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题').last);
    await tester.pumpAndSettle();
    expect(topOf('A 曲'), lessThan(topOf('B 曲')));
  });

  testWidgets('收藏默认是自定义顺序，可以排序，拖一次会存成自定义', (WidgetTester tester) async {
    final FakeSessionStore session = FakeSessionStore();
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: 'B 曲', path: '/music/b.mp3'),
        sampleTrack(title: 'A 曲', path: '/music/a.mp3'),
        sampleTrack(title: 'C 曲', path: '/music/c.mp3'),
      ],
      sessionStore: session,
      seed: (FakeLibraryRepository repo) async {
        for (final String path in <String>[
          '/music/b.mp3',
          '/music/a.mp3',
          '/music/c.mp3',
        ]) {
          await repo.setFavorite(path, true);
        }
      },
    );
    await openFavorites(tester);

    double topOf(String title) => tester.getTopLeft(find.text(title)).dy;
    final Finder sort = find.byKey(
      const ValueKey<String>('library-sort-favorites'),
    );
    final Finder label = find.byKey(
      const ValueKey<String>('library-sort-favorites-label'),
    );

    // 默认「自定义」：按收藏先后（B 先收藏）
    expect(tester.widget<Text>(label).data, '自定义');
    expect(topOf('B 曲'), lessThan(topOf('A 曲')));

    // 按标题排
    await tester.tap(sort);
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(label).data, '标题');
    expect(topOf('A 曲'), lessThan(topOf('B 曲')));

    // 在标题排序下拖一次：顺序落库成自定义，按钮跟着变回「自定义」
    final TrackListView list = tester.widget<TrackListView>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is TrackListView &&
            w.storageKey is PageStorageKey<String> &&
            (w.storageKey! as PageStorageKey<String>).value ==
                'tracks:favorites',
      ),
    );
    expect(list.onReorder, isNotNull, reason: '收藏要有六点抓手');
    list.onReorder!(2, 0);
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(label).data, '自定义', reason: '手动拖过之后就是自定义顺序');
    expect(session.snapshot.favoriteOrder, <String>[
      '/music/c.mp3',
      '/music/b.mp3',
      '/music/a.mp3',
    ], reason: '自定义顺序要存盘：C 被拖到最前，其余保持原相对顺序');
    expect(topOf('C 曲'), lessThan(topOf('B 曲')));
  });

  testWidgets('歌单在标题排序下拖一次，会落库并切回自定义', (WidgetTester tester) async {
    final FakeLibraryRepository repo = await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: 'A 曲', path: '/music/a.mp3'),
        sampleTrack(title: 'B 曲', path: '/music/b.mp3'),
        sampleTrack(title: 'C 曲', path: '/music/c.mp3'),
      ],
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        // 新加的歌排最前：倒着加才能得到 A、B、C 的手动顺序
        for (final String path in <String>[
          '/music/c.mp3',
          '/music/b.mp3',
          '/music/a.mp3',
        ]) {
          await repo.addTrackToPlaylist(playlist.id.toInt(), path);
        }
      },
    );
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    final Finder sort = find.byKey(
      const ValueKey<String>('library-sort-playlist-detail'),
    );
    final Finder label = find.byKey(
      const ValueKey<String>('library-sort-playlist-detail-label'),
    );
    expect(tester.widget<Text>(label).data, '自定义');

    // 先按标题（此时顺序刚好也是 A、B、C）
    await tester.tap(sort);
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(label).data, '标题');

    // 拖动把手仍在：把 C 拖到最前 → 落库 (2, 0)，并切回自定义
    final TrackListView list = tester.widget<TrackListView>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is TrackListView &&
            w.storageKey is PageStorageKey<String> &&
            (w.storageKey as PageStorageKey<String>).value.startsWith(
              'tracks:playlist:',
            ),
      ),
    );
    expect(list.onReorder, isNotNull, reason: '排序视图下也要能拖');
    list.onReorder!(2, 0);
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(label).data, '自定义');
    expect(repo.movePlaylistCalls.last, (1, 2, 0), reason: '按手动顺序落库');
    expect(
      tester.getTopLeft(find.text('C 曲')).dy,
      lessThan(tester.getTopLeft(find.text('A 曲')).dy),
    );
  });

  testWidgets('专辑详情里直接就能搜这张专辑的歌', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
        sampleTrack(title: '晨光', album: '夜之专辑', path: '/music/晨光.mp3'),
      ],
    );
    await _openSection(tester, '专辑');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('albums-list')),
        matching: find.text('夜之专辑'),
      ),
    );
    await tester.pumpAndSettle();

    // 搜索框里也有文字，量列表要用 descendant 限定在详情那张列表里
    Finder inAlbum(String text) => find.descendant(
      of: find.byWidgetPredicate(
        (Widget w) =>
            w is TrackListView &&
            w.storageKey is PageStorageKey<String> &&
            (w.storageKey as PageStorageKey<String>).value.startsWith(
              'tracks:album:',
            ),
      ),
      matching: find.text(text),
    );
    expect(inAlbum('晨光'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '夜航');
    await tester.pumpAndSettle();

    // 外面那层列的是专辑卡片，搜歌名本来就命中不了；进详情后必须就地问列表
    expect(inAlbum('夜航'), findsOneWidget);
    expect(inAlbum('晨光'), findsNothing, reason: '详情页里应当按歌名过滤');
    expect(find.text('播放结果'), findsOneWidget, reason: '此时放的是命中结果，不是整张专辑');

    // 换成搜不到的词：给搜索空态，别显示「这张专辑是空的」
    await tester.enterText(find.byType(TextField), '根本不存在的歌');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的歌曲'), findsOneWidget);
    expect(find.textContaining('这张专辑'), findsOneWidget);
  });

  testWidgets('艺术家详情里直接就能搜这位艺术家的歌', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        // 专辑名给不同值：列表行里有一列显示专辑，同名会干扰按文本断言
        sampleTrack(title: '夜航', album: '专辑一', path: '/music/夜航.mp3'),
        sampleTrack(title: '晨光', album: '专辑二', path: '/music/晨光.mp3'),
      ],
    );
    await _openSection(tester, '艺术家');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('artists-list')),
        matching: find.text('林间电台'),
      ),
    );
    await tester.pumpAndSettle();

    Finder inArtist(String text) => find.descendant(
      of: find.byWidgetPredicate(
        (Widget w) =>
            w is TrackListView &&
            w.storageKey is PageStorageKey<String> &&
            (w.storageKey as PageStorageKey<String>).value.startsWith(
              'tracks:artist:',
            ),
      ),
      matching: find.text(text),
    );
    expect(inArtist('晨光'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '晨光');
    await tester.pumpAndSettle();

    expect(inArtist('晨光'), findsOneWidget);
    expect(inArtist('夜航'), findsNothing);
    expect(find.text('播放结果'), findsOneWidget);
  });

  testWidgets('歌单详情里直接就能搜这个歌单的歌，搜索时不给拖', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '专辑一', path: '/music/夜航.mp3'),
        sampleTrack(title: '晨光', album: '专辑二', path: '/music/晨光.mp3'),
      ],
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/夜航.mp3');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/晨光.mp3');
      },
    );
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    final Finder playlistList = find.byWidgetPredicate(
      (Widget w) =>
          w is TrackListView &&
          w.storageKey is PageStorageKey<String> &&
          (w.storageKey as PageStorageKey<String>).value.startsWith(
            'tracks:playlist:',
          ),
    );
    Finder inPlaylist(String text) =>
        find.descendant(of: playlistList, matching: find.text(text));

    await tester.enterText(find.byType(TextField), '夜航');
    await tester.pumpAndSettle();

    expect(inPlaylist('夜航'), findsOneWidget);
    expect(inPlaylist('晨光'), findsNothing);

    // 看到的是命中子集，拖出来的顺序对不上整张歌单：这时不给把手
    final TrackListView list = tester.widget<TrackListView>(playlistList);
    expect(list.onReorder, isNull, reason: '搜索过滤时拖拽排序没有意义');

    // 清掉搜索词：把手回来
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(tester.widget<TrackListView>(playlistList).onReorder, isNotNull);
  });

  testWidgets('歌单拖拽落库期间不换列表控件（换了文字会抽动一下）', (WidgetTester tester) async {
    final FakeLibraryRepository repo = await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', path: '/music/夜航.mp3'),
        sampleTrack(title: '晨光', album: '夜之专辑', path: '/music/晨光.mp3'),
      ],
      seed: (FakeLibraryRepository repo) async {
        final Playlist playlist = await repo.createPlaylist('晨间');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/夜航.mp3');
        await repo.addTrackToPlaylist(playlist.id.toInt(), '/music/晨光.mp3');
      },
    );
    await openPlaylists(tester);
    await tester.tap(find.text('晨间'));
    await tester.pumpAndSettle();

    // 别的分区（Offstage 常驻）里也有普通 ListView，不能拿「有没有 ListView」
    // 判断，只看这行曲目挂在哪种列表下
    Finder rowIn(Finder list) =>
        find.descendant(of: list, matching: find.text('夜航'));
    expect(rowIn(find.byType(ReorderableListView)), findsOneWidget);

    // 直接触发回调：模拟拖完一次把手
    final TrackListView list = tester.widget<TrackListView>(
      find.byType(TrackListView),
    );
    expect(list.onReorder, isNotNull, reason: '歌单里应当能拖拽排序');

    // 把落库挂住：这样才真的停在「正在落库」这个窗口里观察界面
    repo.movePlaylistGate = Completer<void>();
    list.onReorder!(0, 1);
    await tester.pump();

    // 落库还在飞：控件类型不能变。
    // 原来这里把 onReorder 置 null，TrackListView 会从 ReorderableListView
    // 换成普通 ListView —— 两个类型不同，key 相同也不复用 element，
    // 整列表重建、文字重排一次，观感就是「抽动一下、像刷新」
    expect(
      rowIn(find.byType(ReorderableListView)),
      findsOneWidget,
      reason: '落库期间仍应是可拖拽列表，不能换成普通 ListView',
    );

    // 落库完成：类型仍然不变
    repo.movePlaylistGate!.complete();
    await tester.pumpAndSettle();
    expect(rowIn(find.byType(ReorderableListView)), findsOneWidget);
    expect(repo.movePlaylistCalls, <(int, int, int)>[(1, 0, 1)]);
  });

  testWidgets('歌单分区可新建歌单并展示卡片', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);

    expect(find.text('还没有歌单'), findsOneWidget);
    expect(find.text('0 个歌单'), findsOneWidget);

    await createPlaylistThroughUi(tester, '深夜通勤');

    expect(find.text('深夜通勤'), findsOneWidget);
    expect(find.text('1 个歌单'), findsOneWidget);
    // 两个动作直接摆在卡片右侧，不再收进三点菜单
    expect(find.byTooltip('重命名歌单'), findsOneWidget);
    expect(find.byTooltip('删除歌单'), findsOneWidget);
  });

  testWidgets('新建歌单校验空名与重名', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);

    await tester.tap(find.text('新建歌单').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('歌单名不能为空'), findsOneWidget);

    await tester.enterText(playlistNameField, '通勤');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('通勤'), findsOneWidget);

    await tester.tap(find.text('新建歌单').first);
    await tester.pumpAndSettle();
    await tester.enterText(playlistNameField, '通勤');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('已有同名歌单'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('歌单详情可添加曲目、从歌单移除', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);
    await createPlaylistThroughUi(tester, '通勤');

    await tester.tap(find.text('通勤'));
    await tester.pumpAndSettle();
    expect(find.text('歌单还是空的'), findsOneWidget);

    // 头部四个次要按钮只画图标，靠 tooltip 说明功能
    await tester.tap(find.byTooltip('添加音乐'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byTooltip('添加到歌单'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 弹窗里第一行（拼音序）是潮汐
    expect(find.text('潮汐'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从歌单中移除'));
    await tester.pumpAndSettle();

    expect(find.text('歌单还是空的'), findsOneWidget);
  });

  testWidgets('歌单卡片可删除歌单', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openPlaylists(tester);
    await createPlaylistThroughUi(tester, '通勤');

    await tester.tap(find.byTooltip('删除歌单'));
    await tester.pumpAndSettle();

    expect(find.text('删除「通勤」？'), findsOneWidget);
    await tester.tap(find.text('删除歌单'));
    await tester.pumpAndSettle();

    expect(find.text('还没有歌单'), findsOneWidget);
    expect(find.text('0 个歌单'), findsOneWidget);
  });

  testWidgets('收藏分区空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openFavorites(tester);

    expect(find.text('0 首收藏'), findsOneWidget);
    expect(find.text('还没有收藏'), findsOneWidget);
  });

  testWidgets('在音乐列表收藏后可出现在收藏页，取消后回到空态', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());

    await tester.tap(find.byTooltip('收藏').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await openFavorites(tester);
    expect(find.text('1 首收藏'), findsOneWidget);
    // 列表按拼音排，第一行是潮汐
    expect(find.text('潮汐'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();

    expect(find.text('还没有收藏'), findsOneWidget);
    expect(find.text('0 首收藏'), findsOneWidget);
  });

  testWidgets('历史分区空态且清空按钮禁用', (WidgetTester tester) async {
    await pumpLibrary(tester, tracks: twoTracks());
    await openHistory(tester);

    expect(find.text('0 条播放记录'), findsOneWidget);
    expect(find.text('还没有播放记录'), findsOneWidget);
    final OutlinedButton clearButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '清空历史'),
    );
    expect(clearButton.onPressed, isNull);
  });

  testWidgets('历史按最近播放排序展示', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.recordPlay('/music/夜航.mp3');
        await repo.recordPlay('/music/潮汐.mp3');
      },
    );
    await openHistory(tester);

    expect(find.text('2 条播放记录'), findsOneWidget);
    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('潮汐'), findsOneWidget);

    final double recentY = tester.getTopLeft(find.text('潮汐')).dy;
    final double olderY = tester.getTopLeft(find.text('夜航')).dy;
    expect(recentY, lessThan(olderY), reason: '最近播放的应排在前面');
  });

  testWidgets('清空历史需确认，确认后回到空态', (WidgetTester tester) async {
    await pumpLibrary(
      tester,
      tracks: twoTracks(),
      seed: (FakeLibraryRepository repo) async {
        await repo.recordPlay('/music/夜航.mp3');
      },
    );
    await openHistory(tester);

    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();
    expect(find.text('清空播放历史？'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('0 条播放记录'), findsOneWidget);
    expect(find.text('还没有播放记录'), findsOneWidget);
  });

  testWidgets('正在播放页点歌手，退出播放页并进艺术家详情', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
    await _playAndOpenNowPlaying(tester);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-artist')));
    await tester.pumpAndSettle();

    // 播放页退掉，落在「艺术家」分区的详情里
    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsNothing,
    );
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.text('林间电台'), findsWidgets);
    // 同一页里的另一位歌手不该出现在详情里
    expect(find.text('海岸线'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('正在播放页点专辑，退出播放页并进专辑详情', (WidgetTester tester) async {
    final FakePlaybackService playback = FakePlaybackService(
      isAvailable: true,
      durationSecs: 180,
    );
    await pumpLibrary(tester, tracks: twoTracks(), playback: playback);
    await _playAndOpenNowPlaying(tester);

    await tester.tap(find.byKey(const ValueKey<String>('now-playing-album')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('now-playing-header')),
      findsNothing,
    );
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.text('夜之专辑'), findsWidgets);
    expect(find.text('玻璃海'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// 播一首并打开正在播放页：后面的跳转测试都从这一步开始
Future<void> _playAndOpenNowPlaying(WidgetTester tester) async {
  await tester.tap(find.text('夜航'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  // 点播放条上的曲名（左段中央是播放键，别点正中）
  await tester.tap(
    find.descendant(of: find.byType(PlayerBar), matching: find.text('夜航')),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey<String>('now-playing-header')),
    findsOneWidget,
  );
}
