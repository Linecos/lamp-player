import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/tray_controller.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('tray_manager');

  /// 记录托盘插件收到的所有方法调用
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('trayMenuItems', () {
    test('有曲目时包含播放控制与退出，播放控制可用', () {
      final List<MenuItem> items = trayMenuItems(
        hasTrack: true,
        playing: false,
        desktopLyrics: false,
        desktopLyricLocked: false,
      );
      final Map<String, MenuItem> byKey = <String, MenuItem>{
        for (final MenuItem item in items)
          if (item.key != null) item.key!: item,
      };

      expect(
        byKey.keys,
        containsAll(<String>[
          'play_pause',
          'previous',
          'next',
          'desktop_lyrics',
          'desktop_lyric_lock',
          'show',
          'quit',
        ]),
      );
      expect(byKey['play_pause']!.label, '播放');
      expect(byKey['play_pause']!.disabled, isFalse);
      expect(byKey['previous']!.disabled, isFalse);
      expect(byKey['next']!.disabled, isFalse);
      expect(byKey['quit']!.label, '退出');
    });

    test('播放中显示「暂停」', () {
      final List<MenuItem> items = trayMenuItems(
        hasTrack: true,
        playing: true,
        desktopLyrics: false,
        desktopLyricLocked: false,
      );
      final MenuItem playPause = items.firstWhere(
        (MenuItem item) => item.key == 'play_pause',
      );

      expect(playPause.label, '暂停');
    });

    test('无曲目时播放控制禁用，显示主窗口与退出仍可用', () {
      final List<MenuItem> items = trayMenuItems(
        hasTrack: false,
        playing: false,
        desktopLyrics: false,
        desktopLyricLocked: false,
      );
      final Map<String, MenuItem> byKey = <String, MenuItem>{
        for (final MenuItem item in items)
          if (item.key != null) item.key!: item,
      };

      expect(byKey['play_pause']!.disabled, isTrue);
      expect(byKey['previous']!.disabled, isTrue);
      expect(byKey['next']!.disabled, isTrue);
      expect(byKey['show']!.disabled, isFalse);
      expect(byKey['quit']!.disabled, isFalse);
    });

    test('含三个分隔线，菜单结构稳定', () {
      final List<MenuItem> items = trayMenuItems(
        hasTrack: true,
        playing: false,
        desktopLyrics: false,
        desktopLyricLocked: false,
      );
      expect(
        items.where((MenuItem item) => item.type == 'separator').length,
        3,
      );
    });

    test('桌面歌词未显示时锁定项置灰，显示后勾选态跟随状态', () {
      Map<String, MenuItem> byKey({
        required bool desktopLyrics,
        required bool desktopLyricLocked,
      }) => <String, MenuItem>{
        for (final MenuItem item in trayMenuItems(
          hasTrack: true,
          playing: false,
          desktopLyrics: desktopLyrics,
          desktopLyricLocked: desktopLyricLocked,
        ))
          if (item.key != null) item.key!: item,
      };

      final Map<String, MenuItem> hidden = byKey(
        desktopLyrics: false,
        desktopLyricLocked: false,
      );
      expect(hidden['desktop_lyrics']!.type, 'checkbox');
      expect(hidden['desktop_lyrics']!.label, '显示桌面歌词');
      expect(hidden['desktop_lyrics']!.checked, isFalse);
      expect(hidden['desktop_lyrics']!.disabled, isFalse);
      expect(hidden['desktop_lyric_lock']!.type, 'checkbox');
      expect(hidden['desktop_lyric_lock']!.label, '锁定桌面歌词');
      expect(hidden['desktop_lyric_lock']!.disabled, isTrue);

      final Map<String, MenuItem> shown = byKey(
        desktopLyrics: true,
        desktopLyricLocked: true,
      );
      expect(shown['desktop_lyrics']!.checked, isTrue);
      expect(shown['desktop_lyric_lock']!.disabled, isFalse);
      expect(shown['desktop_lyric_lock']!.checked, isTrue);
    });
  });

  group('TrayController', () {
    test('右键请求弹出上下文菜单（Windows 不会自动弹）', () async {
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );

      controller.onTrayIconRightMouseDown();
      await Future<void>.delayed(Duration.zero);

      expect(
        calls.map((MethodCall call) => call.method),
        contains('popUpContextMenu'),
      );
    });

    test('左键唤起窗口', () async {
      int shown = 0;
      final TrayController controller = TrayController(
        onShow: () async => shown += 1,
        onQuit: () async {},
      );

      controller.onTrayIconMouseDown();
      await Future<void>.delayed(Duration.zero);

      expect(shown, 1);
    });

    test('菜单点击分发到播放控制与退出', () async {
      int toggled = 0;
      int next = 0;
      int previous = 0;
      int quit = 0;
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async => quit += 1,
      );
      controller.bindPlayback(
        onTogglePlay: () => toggled += 1,
        onNext: () => next += 1,
        onPrevious: () => previous += 1,
      );

      controller.onTrayMenuItemClick(MenuItem(key: 'play_pause', label: '播放'));
      controller.onTrayMenuItemClick(MenuItem(key: 'next', label: '下一首'));
      controller.onTrayMenuItemClick(MenuItem(key: 'previous', label: '上一首'));
      controller.onTrayMenuItemClick(MenuItem(key: 'quit', label: '退出'));
      await Future<void>.delayed(Duration.zero);

      expect(toggled, 1);
      expect(next, 1);
      expect(previous, 1);
      expect(quit, 1);
    });

    test('菜单点击分发到桌面歌词开关', () async {
      int toggled = 0;
      int locked = 0;
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );
      controller.bindDesktopLyrics(
        onToggle: () => toggled += 1,
        onToggleLock: () => locked += 1,
      );

      controller.onTrayMenuItemClick(
        MenuItem(key: 'desktop_lyrics', label: '显示桌面歌词'),
      );
      controller.onTrayMenuItemClick(
        MenuItem(key: 'desktop_lyric_lock', label: '锁定桌面歌词'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(toggled, 1);
      expect(locked, 1);

      // 解绑后点击不抛异常
      controller.unbindDesktopLyrics();
      expect(
        () => controller.onTrayMenuItemClick(
          MenuItem(key: 'desktop_lyrics', label: '显示桌面歌词'),
        ),
        returnsNormally,
      );
    });

    test('updateDesktopLyrics 刷新勾选态与禁用态，同状态不重复下发', () async {
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );
      await controller.init();
      calls.clear();

      await controller.updateDesktopLyrics(visible: true, locked: false);
      expect(
        calls.where((MethodCall c) => c.method == 'setContextMenu'),
        hasLength(1),
      );

      // 相同状态不再重建
      await controller.updateDesktopLyrics(visible: true, locked: false);
      expect(
        calls.where((MethodCall c) => c.method == 'setContextMenu'),
        hasLength(1),
      );

      // 隐藏后：显示项取消勾选，锁定项置灰
      await controller.updateDesktopLyrics(visible: false, locked: false);
      final List<MethodCall> menus = calls
          .where((MethodCall c) => c.method == 'setContextMenu')
          .toList();
      expect(menus, hasLength(2));
      final Map<Object?, Object?> args =
          menus.last.arguments as Map<Object?, Object?>;
      final List<Object?> items =
          ((args['menu'] as Map<Object?, Object?>)['items'] as List<Object?>);
      final Map<Object?, Object?> lyrics = items
          .cast<Map<Object?, Object?>>()
          .firstWhere(
            (Map<Object?, Object?> item) => item['key'] == 'desktop_lyrics',
          );
      final Map<Object?, Object?> lock = items
          .cast<Map<Object?, Object?>>()
          .firstWhere(
            (Map<Object?, Object?> item) => item['key'] == 'desktop_lyric_lock',
          );
      expect(lyrics['checked'], isFalse);
      expect(lock['disabled'], isTrue);

      await controller.dispose();
    });

    test('init 下发的菜单里桌面歌词项默认未勾选、锁定项置灰', () async {
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );

      await controller.init();

      final MethodCall menuCall = calls.lastWhere(
        (MethodCall call) => call.method == 'setContextMenu',
      );
      final Map<Object?, Object?> args =
          (menuCall.arguments as Map<Object?, Object?>);
      final List<Object?> items =
          ((args['menu'] as Map<Object?, Object?>)['items'] as List<Object?>);
      final Map<Object?, Object?> lyrics = items
          .cast<Map<Object?, Object?>>()
          .firstWhere(
            (Map<Object?, Object?> item) => item['key'] == 'desktop_lyrics',
          );
      final Map<Object?, Object?> lock = items
          .cast<Map<Object?, Object?>>()
          .firstWhere(
            (Map<Object?, Object?> item) => item['key'] == 'desktop_lyric_lock',
          );

      expect(lyrics['checked'], isFalse);
      expect(lyrics['disabled'], isFalse);
      expect(lock['disabled'], isTrue);

      await controller.dispose();
    });

    test('未绑定播放回调时点击播放项不抛异常', () {
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );

      expect(
        () => controller.onTrayMenuItemClick(
          MenuItem(key: 'play_pause', label: '播放'),
        ),
        returnsNormally,
      );
      controller.unbindPlayback();
    });

    test('init 下发图标、提示与初始菜单', () async {
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );

      await controller.init();

      expect(controller.available, isTrue);
      final List<String> methods = calls
          .map((MethodCall call) => call.method)
          .toList();
      expect(
        methods,
        containsAll(<String>['setIcon', 'setToolTip', 'setContextMenu']),
      );

      // 初始菜单：无曲目 → 播放项禁用
      final MethodCall menuCall = calls.lastWhere(
        (MethodCall call) => call.method == 'setContextMenu',
      );
      final Map<Object?, Object?> args =
          (menuCall.arguments as Map<Object?, Object?>);
      final List<Object?> items =
          ((args['menu'] as Map<Object?, Object?>)['items'] as List<Object?>);
      final Map<Object?, Object?> playPause = items
          .cast<Map<Object?, Object?>>()
          .firstWhere(
            (Map<Object?, Object?> item) => item['key'] == 'play_pause',
          );
      expect(playPause['disabled'], isTrue);
      expect(playPause['label'], '播放');

      await controller.dispose();
    });

    test('updatePlayback 改变菜单，同状态不重复下发', () async {
      final TrayController controller = TrayController(
        onShow: () async {},
        onQuit: () async {},
      );
      await controller.init();
      calls.clear();

      await controller.updatePlayback(hasTrack: true, playing: false);
      expect(
        calls.where((MethodCall c) => c.method == 'setContextMenu'),
        hasLength(1),
      );

      // 相同状态不再重建
      await controller.updatePlayback(hasTrack: true, playing: false);
      expect(
        calls.where((MethodCall c) => c.method == 'setContextMenu'),
        hasLength(1),
      );

      // 进入播放态：文案变「暂停」
      await controller.updatePlayback(hasTrack: true, playing: true);
      final List<MethodCall> menus = calls
          .where((MethodCall c) => c.method == 'setContextMenu')
          .toList();
      expect(menus, hasLength(2));
      final Map<Object?, Object?> args =
          menus.last.arguments as Map<Object?, Object?>;
      final List<Object?> items =
          ((args['menu'] as Map<Object?, Object?>)['items'] as List<Object?>);
      final Map<Object?, Object?> playPause = items
          .cast<Map<Object?, Object?>>()
          .firstWhere(
            (Map<Object?, Object?> item) => item['key'] == 'play_pause',
          );
      expect(playPause['label'], '暂停');

      await controller.dispose();
    });
  });
}
